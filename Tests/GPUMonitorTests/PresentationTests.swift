import XCTest
@testable import GPUMonitor

final class PresentationTests: XCTestCase {
    func testOccupiedPresentationDoesNotChangeWhenComputeLoadDrops() {
        var device = Accelerator(id: "0", index: 0, chip: 0, kind: .ascend, name: "910B3", utilization: 80, memoryUsedMiB: 50000, memoryTotalMiB: 65536, health: "OK", processes: [ComputeProcess(pid: 42, user: "user", name: "python", memoryMiB: 50000)], processesKnown: true)
        XCTAssertEqual(device.state, .busy)
        XCTAssertEqual(device.availabilityTitle, "占用")
        device.utilization = 0
        XCTAssertEqual(device.state, .occupied)
        XCTAssertEqual(device.availabilityTitle, "占用")
        device.processes = []
        XCTAssertEqual(device.availabilityTitle, "占用", "Residual allocated device memory must not display as idle")
        device.memoryUsedMiB = 0
        XCTAssertEqual(device.availabilityTitle, "空闲")
        device.processesKnown = false
        XCTAssertEqual(device.availabilityTitle, "未知")
    }
    func testDefaultChipIsHiddenButMultipleChipsRemainDistinct() {
        var device = Accelerator(id: "npu-0-0", index: 0, chip: 0, kind: .ascend, name: "910B3", utilization: 0, memoryUsedMiB: 0, memoryTotalMiB: 65536)
        XCTAssertEqual(device.compactLabel, "NPU 0")
        XCTAssertTrue(device.label.contains("Chip 0"))
        device.chip = 1
        XCTAssertEqual(device.compactLabel, "NPU 0.1")
    }
}

final class OccupancyRegressionTests: XCTestCase {
    private func idle910B() -> Accelerator {
        Accelerator(id: "npu-2-0", index: 2, chip: 0, kind: .ascend, name: "910B3", utilization: 0,
                    memoryUsedMiB: 3380, memoryTotalMiB: 65536, health: "OK", processesKnown: true)
    }
    func test910BBackgroundMemoryDoesNotMeanSomeoneIsUsingTheCard() {
        let device = idle910B()
        XCTAssertEqual(device.state, .idle)
        XCTAssertEqual(device.memoryUsedMiB, 3380, "Do not subtract a guessed reservation from displayed HBM")
        XCTAssertTrue(device.occupancyReason.contains("容差"))
    }
    func test910BToleranceNeverOverridesProcessesLoadHealthOrMissingData() {
        var device = idle910B()
        device.processes = [ComputeProcess(pid: 123, user: nil, name: "python", memoryMiB: 1)]
        XCTAssertEqual(device.state, .occupied)
        device.processes = []
        device.utilization = 5
        XCTAssertEqual(device.state, .busy)
        device.utilization = 0
        device.processesKnown = false
        XCTAssertEqual(device.state, .unknown)
        device.processesKnown = true
        device.health = "WARNING"
        XCTAssertEqual(device.state, .unknown)
        device.health = nil
        XCTAssertEqual(device.state, .unknown)
        device.health = "OK"
        device.utilization = nil
        XCTAssertEqual(device.state, .unknown)
        device.utilization = 0
        device.memoryUsedMiB = nil
        XCTAssertEqual(device.state, .unknown)
        device.memoryUsedMiB = 5000
        XCTAssertEqual(device.state, .occupied)
    }
    func testBackgroundToleranceIsNotAppliedToOtherModelsOrSmallMemoryDevices() {
        var device = idle910B()
        device.kind = .nvidia; device.name = "RTX 3080 Ti"
        XCTAssertEqual(device.state, .occupied)
        device.kind = .ascend; device.name = "310P"
        XCTAssertEqual(device.state, .occupied)
        device.name = "910B3"; device.memoryTotalMiB = 8192
        XCTAssertEqual(device.state, .occupied)
    }
    func test910BRealTableWithBaselineAndNoProcesses() throws {
        let raw = TelemetryTests().modern.replacingOccurrences(of: "128/ 65536", with: "3380/ 65536")
        let parsed = try SnapshotParser.parse(raw)
        XCTAssertEqual(parsed.devices[0].state, .busy)
        XCTAssertEqual(parsed.devices[1].state, .idle)
        let malformed = raw.replacingOccurrences(of: "| 0 0 | 1001 | python | 52765 |", with: "| malformed process row |")
        XCTAssertEqual(try SnapshotParser.parse(malformed).devices[1].state, .unknown)
    }
    @MainActor func testMenuRatioAndServerSummaryExcludeStaleCardsFromIdle() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MonitorStore(configURL: url, startPolling: false)
        let first = Server(name: "first", host: "first")
        let second = Server(name: "second", host: "second")
        store.servers = [first, second]
        let idle = idle910B()
        var busy = idle; busy.utilization = 90
        store.statuses[first.id] = ServerStatus(snapshot: Snapshot(devices: [idle, busy]))
        store.statuses[second.id] = ServerStatus(snapshot: Snapshot(devices: [idle], date: Date().addingTimeInterval(-300)))
        XCTAssertEqual(store.menuTitle, "1/3")
        XCTAssertEqual(store.summary(serverID: first.id).total, 2)
        XCTAssertEqual(store.summary(serverID: first.id).occupied, 1)
        XCTAssertEqual(store.summary(serverID: second.id).idle, 0)
        XCTAssertEqual(store.summary(serverID: second.id).unknown, 1)
        store.paused = true
        XCTAssertEqual(store.menuTitle, "1/3")
    }
}
