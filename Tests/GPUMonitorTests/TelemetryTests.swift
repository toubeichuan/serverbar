import XCTest
@testable import GPUMonitor

final class TelemetryTests: XCTestCase {
    let modern = """
    __GM_NPU__
    | NPU Name | Health | Power(W) Temp(C) Hugepages-Usage(page) |
    | Chip | Bus-Id | AICore(%) Memory-Usage(MB) HBM-Usage(MB) |
    | 0 910B3 | OK | 121.7 48 0 / 0 |
    | 0 | 0000:C1:00.0 | 15 0 / 0 56124/ 65536 |
    | 1 910B3 | OK | 122.8 49 0 / 0 |
    | 0 | 0000:01:00.0 | 0 0 / 0 128/ 65536 |
    | NPU Chip | Process id | Process name | Process memory(MB) |
    | 0 0 | 1001 | python | 52765 |
    __GM_PS__
    1001 alice python
    __GM_PS_OK__
    __GM_PROGRAMS__
    ["1001", "python train.py"]
    """

    func testActual910B3SingleChipColumnAndInlineProcesses() throws {
        let snapshot = try SnapshotParser.parse(modern)
        XCTAssertEqual(snapshot.devices.count, 2)
        XCTAssertEqual(snapshot.devices[0].temperature, 48)
        XCTAssertEqual(snapshot.devices[0].powerWatts, 121.7)
        XCTAssertEqual(snapshot.devices[0].memoryUsedMiB, 56124)
        XCTAssertEqual(snapshot.devices[0].processes[0].user, "alice")
        XCTAssertEqual(snapshot.devices[0].processes[0].program, "python train.py")
        XCTAssertEqual(snapshot.devices[1].state, .idle)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }
    func testCPUAndNetworkUseDeltasNotLifetimeAverages() {
        let old = HostTelemetry(uptime: 100, cpuTicks: ["cpu": CPUTicks(total: 1000, idle: 700), "cpu0": CPUTicks(total: 1000, idle: 700)],
                                interfaces: [NetworkInterface(name: "eth0", received: 1000, sent: 500)])
        var next = HostTelemetry(uptime: 110, cpuTicks: ["cpu": CPUTicks(total: 1200, idle: 800), "cpu0": CPUTicks(total: 1200, idle: 800)],
                                 interfaces: [NetworkInterface(name: "eth0", received: 3000, sent: 1500)])
        next.calculateRates(previous: old)
        XCTAssertEqual(next.cpuUsage, 50)
        XCTAssertEqual(next.coreUsage["cpu0"], 50)
        XCTAssertEqual(next.interfaces[0].receiveRate, 200)
        XCTAssertEqual(next.interfaces[0].sendRate, 100)
    }
    func testCounterResetRebootAndFirstSampleAreUnknown() {
        let old = HostTelemetry(uptime: 100, interfaces: [NetworkInterface(name: "eth0", received: 1000, sent: 500)])
        var rebooted = HostTelemetry(uptime: 2, interfaces: [NetworkInterface(name: "eth0", received: 20, sent: 10)])
        rebooted.calculateRates(previous: old)
        XCTAssertNil(rebooted.interfaces[0].receiveRate)
        var reset = rebooted; reset.uptime = 110
        reset.calculateRates(previous: old)
        XCTAssertNil(reset.interfaces[0].receiveRate)
        reset.calculateRates(previous: nil)
        XCTAssertNil(reset.cpuUsage)
    }
    func testHostParsingAndGPUFailureRemainIndependent() throws {
        let raw = """
        __GM_GPU_ERROR__
        Driver not available
        __GM_UPTIME__
        200.50 1022.0
        __GM_CPU__
        cpu 100 0 50 800 20 5 5 20 10 0
        cpu0 100 0 50 800 20 5 5 20 10 0
        __GM_CPU_MODEL__
        Example CPU
        __GM_MEMORY__
        MemTotal: 8388608 kB
        MemAvailable: 2097152 kB
        SwapTotal: 1024 kB
        SwapFree: 512 kB
        __GM_NETWORK__
          lo: 1000 0 0 0 0 0 0 0 1000 0 0 0 0 0 0 0
          eth0: 2000 0 0 0 0 0 0 0 5000 0 0 0 0 0 0 0
        __GM_ROUTE__
        eth0
        __GM_DISK__
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sda1 100000 40000 60000 40% /
        """
        let snapshot = try SnapshotParser.parse(raw)
        let t = try XCTUnwrap(snapshot.telemetry)
        XCTAssertTrue(snapshot.devices.isEmpty)
        XCTAssertNotNil(snapshot.gpuError)
        XCTAssertEqual(t.cpuTicks["cpu"]?.total, 1000)
        XCTAssertEqual(t.memoryUsedMiB, 6144)
        XCTAssertEqual(t.interfaces.count, 1)
        XCTAssertEqual(t.primaryInterface, "eth0")
        XCTAssertEqual(t.diskUsedKiB, 40000)
    }
    func testHiddenPanelsDoNotRunTheirProbes() {
        let script = SSHClient.probe(kind: .auto, panels: [.cpu, .network])
        XCTAssertFalse(script.contains("nvidia-smi"))
        XCTAssertFalse(script.contains("/proc/meminfo"))
        XCTAssertFalse(script.contains("df -Pk"))
        XCTAssertTrue(script.contains("/proc/stat"))
        XCTAssertTrue(script.contains("/proc/net/dev"))
    }
    @MainActor func testPanelPreferencesPersistAndOldConfigurationMigrates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("servers.json")
        try #"{"version":1,"servers":[],"interval":10}"#.write(to: path, atomically: true, encoding: .utf8)
        let store = MonitorStore(configURL: path, startPolling: false)
        XCTAssertTrue(store.panels.visible.contains(.cpu))
        store.setPanel(.disk, visible: true)
        store.setPanel(.network, visible: false)
        let restored = MonitorStore(configURL: path, startPolling: false)
        XCTAssertTrue(restored.panels.visible.contains(.disk))
        XCTAssertFalse(restored.panels.visible.contains(.network))
        XCTAssertEqual(restored.interval, 10)
    }
}

final class LiveServerTests: XCTestCase {
    func testConfiguredServersReadOnly() async throws {
        let hostList = ProcessInfo.processInfo.environment["GPU_MONITOR_LIVE_HOSTS"] ?? ""
        try XCTSkipIf(hostList.isEmpty, "Live SSH verification is opt-in.")
        for host in hostList.split(separator: ",").map(String.init) {
            let server = Server(name: host, host: host)
            let first = try await SSHClient.collect(server)
            var second = try await SSHClient.collect(server)
            second.telemetry?.calculateRates(previous: first.telemetry)
            XCTAssertFalse(first.devices.isEmpty, host)
            XCTAssertNil(first.gpuError, host)
            XCTAssertNotNil(second.telemetry?.cpuUsage, host)
            XCTAssertNotNil(second.telemetry?.primaryNetwork?.receiveRate, host)
            XCTAssertFalse(first.telemetry?.disks.isEmpty ?? true, host)
            XCTAssertFalse(first.telemetry?.volumes.isEmpty ?? true, host)
            XCTAssertNotNil(second.telemetry?.diskReadRate, host)
            XCTAssertNotNil(second.telemetry?.diskWriteRate, host)
            XCTAssertTrue(first.devices.allSatisfy { $0.temperature != nil }, host)
            XCTAssertTrue(first.devices.allSatisfy { $0.processesKnown }, host)
            print("LIVE \(host): \(first.devices.count) devices; CPU/network/disk rates valid; program labels \(first.devices.flatMap(\.processes).filter { $0.program != nil }.count).")
        }
    }
}
