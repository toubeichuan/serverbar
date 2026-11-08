import XCTest
@testable import GPUMonitor

final class SSHConfigTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".ssh/conf.d"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func write(_ relative: String, _ content: String) throws {
        try content.write(to: folder.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }
    func testIncludesAliasesQuotingAndWildcards() throws {
        try write(".ssh/config", """
        Host *
          User test
        Include conf.d/*.conf
        Host gpu-01 gpu-02 !blocked *.lab
          HostName 10.0.0.1
        Host="quoted-host" # comment
        Host gpu-01
        Match all
          IdentityFile ~/.ssh/key
        """)
        try write(".ssh/conf.d/b.conf", "Host ascend-02")
        try write(".ssh/conf.d/a.conf", "Host ascend-01\nInclude ~/.ssh/config")
        let result = SSHConfigReader(home: folder.path).read()
        XCTAssertEqual(result.hosts.map(\.alias), ["ascend-01", "ascend-02", "gpu-01", "gpu-02", "quoted-host"])
        XCTAssertEqual(result.warnings.count, 1)
    }
    func testIncludesRelativeToSSHDirectoryNotIncludedFile() throws {
        try write(".ssh/config", "Include conf.d/a.conf")
        try write(".ssh/conf.d/a.conf", "Include extra.conf")
        try write(".ssh/extra.conf", "Host nested")
        XCTAssertEqual(SSHConfigReader(home: folder.path).read().hosts.map(\.alias), ["nested"])
    }
    func testEnvironmentIncludeAndMissingFile() throws {
        try write(".ssh/config", "Include $" + "{EXTRA}/hosts\nInclude nonexistent*.conf")
        try write("hosts", "Host env-server")
        let result = SSHConfigReader(home: folder.path, environment: ["EXTRA": folder.path]).read()
        XCTAssertEqual(result.hosts.map(\.alias), ["env-server"])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertFalse(SSHConfigReader(home: folder.path).read(path: folder.appendingPathComponent("missing").path).warnings.isEmpty)
    }
    func testQuotedHashAndEquals() {
        XCTAssertEqual(SSHConfigReader.tokens(#"Host = "gpu#1" test # ignored"#), ["Host", "gpu#1", "test"])
        XCTAssertEqual(SSHConfigReader.tokens("Host=test"), ["Host", "test"])
    }
    func testCommandInjectionRejectedAndArgumentsSeparated() {
        for host in ["-oProxyCommand=bad", "host;id", "host\nwhoami", "$(id)", "host name", ""] {
            XCTAssertFalse(Server.validHost(host), host)
        }
        XCTAssertTrue(Server.validHost("alice@10.0.0.1"))
        XCTAssertTrue(Server.validHost("2001:db8::1"))
        let server = Server(name: "test", host: "safe-host", port: 2222, user: "alice", identityFile: "/tmp/key with space")
        let args = SSHClient.arguments(for: server, command: "echo test")
        XCTAssertTrue(args.contains("/tmp/key with space"))
        XCTAssertEqual(Array(args.suffix(3)), ["--", "safe-host", "echo test"])
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }
}

final class SnapshotTests: XCTestCase {
    let gpu = """
    __GM_GPU__
    0, GPU-one, NVIDIA RTX 4090, 0, 120, 24576, 39
    1, GPU-two, NVIDIA A100, 93, 45056, 81920, 61
    __GM_APPS__
    GPU-two, 381, "/opt/a,b/python", 44032
    GPU-two, 382, python, 512
    __GM_APPS_OK__
    __GM_PS__
    381 alice python
    382 bob python
    __GM_PS_OK__
    """
    let npu = """
    __GM_NPU__
    | NPU Name | Health | Power(W) Temp(C) Hugepages-Usage(page) |
    | Chip Device | Bus-Id | AICore(%) Memory-Usage(MB) HBM-Usage(MB) |
    | 0 Ascend 910B | OK | 91.2 46 0 / 0 |
    | 0 0 | 0000:01:00.0 | 87 1000 / 65536 40960 / 65536 |
    | 1 Ascend 910B | OK | 90.1 40 0 / 0 |
    | 0 1 | 0000:02:00.0 | 0 1000 / 65536 120 / 65536 |
    __GM_NPU_PROC__ 0
    | NPU ID | Chip ID | Process ID | Process Memory(MB) |
    | 0 | 0 | 915 | 40800 |
    __GM_NPU_PROC_OK__ 0
    __GM_NPU_PROC__ 1
    | NPU ID | Chip ID | Process ID | Process Memory(MB) |
    __GM_NPU_PROC_OK__ 1
    __GM_PS__
    915 researcher python
    __GM_PS_OK__
    """
    func testNVIDIAOwnersMemoryAndQuotedCSV() throws {
        let snapshot = try SnapshotParser.parse(gpu)
        XCTAssertEqual(snapshot.devices.count, 2)
        XCTAssertTrue(snapshot.devices[0].idleCandidate)
        XCTAssertEqual(snapshot.devices[1].owners, "alice, bob")
        XCTAssertEqual(snapshot.devices[1].processes[0].name, "/opt/a,b/python")
        XCTAssertEqual(snapshot.devices[1].state, .busy)
    }
    func testAscendHBMAndChipIdentity() throws {
        let snapshot = try SnapshotParser.parse(npu)
        XCTAssertEqual(snapshot.devices.map(\.id), ["npu-0-0", "npu-1-0"])
        XCTAssertEqual(snapshot.devices[0].memoryUsedMiB, 40960)
        XCTAssertEqual(snapshot.devices[0].processes.first?.user, "researcher")
        XCTAssertEqual(snapshot.devices[1].state, .idle)
    }
    func testMultiChipAscendDoesNotDropSecondChip() throws {
        let modified = npu.replacingOccurrences(of: "| 0 0 | 0000:01:00.0 | 87 1000 / 65536 40960 / 65536 |",
                                  with: "| 0 0 | 0000:01:00.0 | 87 1000 / 65536 40960 / 65536 |\n| 1 1 | 0000:01:00.1 | 0 1000 / 65536 128 / 65536 |")
        let snapshot = try SnapshotParser.parse(modified)
        XCTAssertEqual(snapshot.devices.count, 3)
        XCTAssertEqual(snapshot.devices[1].id, "npu-0-1")
        XCTAssertTrue(snapshot.devices[1].processes.isEmpty)
    }
    func testMissingOptionalCommandsNeverMeansIdle() throws {
        let snapshot = try SnapshotParser.parse(gpu.replacingOccurrences(of: "__GM_APPS_OK__", with: ""))
        XCTAssertEqual(snapshot.devices[0].state, .unknown)
        XCTAssertFalse(snapshot.warnings.isEmpty)
        let unknown = try SnapshotParser.parse(npu.replacingOccurrences(of: "__GM_NPU_PROC_OK__ 1", with: ""))
        XCTAssertEqual(unknown.devices[1].state, .unknown)
    }
    func testUnknownMetricsAndMalformedProcessRows() throws {
        let raw = gpu.replacingOccurrences(of: "0, 120, 24576, 39", with: "[N/A], [N/A], 24576, [N/A]")
        XCTAssertEqual(try SnapshotParser.parse(raw).devices[0].state, .unknown)
        let bad = gpu.replacingOccurrences(of: "__GM_APPS__", with: "__GM_APPS__\nbad-row")
        XCTAssertFalse(try SnapshotParser.parse(bad).devices[0].processesKnown)
    }
    func testOccupiedDespiteZeroUtilization() throws {
        var device = try SnapshotParser.parse(gpu).devices[1]
        device.utilization = 0
        XCTAssertEqual(device.state, .occupied)
        device.processes = []
        XCTAssertEqual(device.state, .occupied)
    }
    func testUnknownOwnerRemainsOccupied() throws {
        let snapshot = try SnapshotParser.parse(gpu.replacingOccurrences(of: "381 alice python", with: ""))
        XCTAssertNil(snapshot.devices[1].processes[0].user)
        XCTAssertFalse(snapshot.devices[1].idleCandidate)
    }
    func testIdleDoesNotFlickerAtTenSecondBoundaries() throws {
        for offset in [0.0, 9.8, 10.1, 19.9, 30.0] {
            var snapshot = try SnapshotParser.parse(gpu)
            snapshot.date = Date().addingTimeInterval(offset)
            XCTAssertEqual(snapshot.devices[0].state, .idle)
        }
        var device = try SnapshotParser.parse(gpu).devices[0]
        device.processesKnown = false
        XCTAssertEqual(device.state, .unknown)
        device.processes = [ComputeProcess(pid: 101, user: "alice", name: "python", memoryMiB: 10)]
        XCTAssertEqual(device.state, .occupied)
    }
    func testBrokenDeviceOutputFailsInsteadOfSilentlyDroppingCard() {
        XCTAssertThrowsError(try SnapshotParser.parse("__GM_GPU__\nbad, row"))
        XCTAssertThrowsError(try SnapshotParser.parse("__GM_NPU__\n| 0 Ascend 910B | OK | 90 40 |"))
        XCTAssertThrowsError(try SnapshotParser.parse("login banner only"))
    }
    func testEightDeviceLimitIsVisible() throws {
        let rows = (0..<9).map { "\($0), GPU-\($0), NVIDIA, 0, 0, 24576, 40" }.joined(separator: "\n")
        let snapshot = try SnapshotParser.parse("__GM_GPU__\n" + rows + "\n__GM_APPS__\n__GM_APPS_OK__\n__GM_PS__\n__GM_PS_OK__")
        XCTAssertEqual(snapshot.devices.count, 8)
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("9") })
    }
    func testStaleDataAndErrorAreNeverFresh() {
        let old = Snapshot(devices: [], date: Date().addingTimeInterval(-65))
        XCTAssertTrue(ServerStatus(snapshot: old).stale())
        XCTAssertTrue(ServerStatus(snapshot: Snapshot(devices: []), error: "offline").stale())
        XCTAssertFalse(ServerStatus(snapshot: Snapshot(devices: [])).stale())
    }
}

final class CommandTests: XCTestCase {
    func testCapturesLargeStdoutAndStderrWithoutDeadlock() async throws {
        let result = try await CommandRunner.run(executable: "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 9000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.components(separatedBy: "\n").count, 9001)
        XCTAssertEqual(result.stderr.components(separatedBy: "\n").count, 9001)
    }
    func testTimeoutStopsProcess() async throws {
        let start = Date()
        do {
            _ = try await CommandRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.15)
            XCTFail("Should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testCancellationStopsProcess() async throws {
        let start = Date()
        let task = Task { try await CommandRunner.run(executable: "/bin/sleep", arguments: ["10"]) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testRemoteScriptsAreValidPOSIXShell() async throws {
        for kind in DeviceKind.allCases {
            let output = try await CommandRunner.run(executable: "/bin/sh", arguments: ["-n", "-c", SSHClient.probe(kind: kind)])
            XCTAssertEqual(output.status, 0, output.stderr)
        }
    }
    func testProbeThroughMockVendorCommandsIncludingNumericAscendModel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ascend = """
        #!/bin/sh
        if [ "$*" = "info" ]; then
          echo '| 0 910B4 | OK | 80 42 0 / 0 |'
          echo '| 0 0 | 0000:01:00.0 | 0 128 / 65536 |'
        else
          echo '| NPU ID | Chip ID | Process ID | Process Memory(MB) |'
          echo '| 0 | 0 | 999999 | 8192 |'
        fi
        """
        let nvidia = """
        #!/bin/sh
        case "$1" in
          -L) echo 'GPU 0: GPU-mock';;
          --query-gpu=*) echo '0, GPU-mock, NVIDIA, 0, 128, 24576, 40';;
          --query-compute-apps=*) :;;
        esac
        """
        let ps = "#!/bin/sh\necho '999999 tester python'\n"
        for (name, script) in [("npu-smi", ascend), ("nvidia-smi", nvidia), ("ps", ps)] {
            let path = folder.appendingPathComponent(name)
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        for kind in [DeviceKind.nvidia, .ascend, .auto] {
            let result = try await CommandRunner.run(executable: "/usr/bin/env",
                arguments: ["PATH=\(folder.path):/usr/bin:/bin", "/bin/sh", "-c", SSHClient.probe(kind: kind)])
            XCTAssertEqual(result.status, 0, result.stderr)
            let snapshot = try SnapshotParser.parse(result.stdout)
            XCTAssertEqual(snapshot.devices.count, 1)
            if kind == .ascend {
                XCTAssertEqual(snapshot.devices[0].processes.first?.pid, 999999)
                XCTAssertEqual(snapshot.devices[0].state, .occupied)
            } else { XCTAssertTrue(snapshot.devices[0].idleCandidate) }
        }
    }
}

final class PersistenceTests: XCTestCase {
    @MainActor func testSaveReloadAndDemoNeverPersistsFakeHosts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        let store = MonitorStore(configURL: url, startPolling: false)
        store.paused = true
        XCTAssertTrue(store.add([Server(name: "Lab", host: "example", enabled: false)]))
        store.setInterval(30)
        let original = try Data(contentsOf: url)
        store.enterDemo()
        XCTAssertEqual(store.servers.count, 3)
        XCTAssertEqual(store.summary().idle, 5)
        XCTAssertEqual(try Data(contentsOf: url), original)
        store.leaveDemo()
        XCTAssertEqual(store.servers.first?.host, "example")
        let loaded = MonitorStore(configURL: url, startPolling: false)
        XCTAssertEqual(loaded.servers.count, 1)
        XCTAssertEqual(loaded.interval, 30)
        loaded.remove(loaded.servers[0])
        XCTAssertTrue(MonitorStore(configURL: url, startPolling: false).servers.isEmpty)
    }
}
