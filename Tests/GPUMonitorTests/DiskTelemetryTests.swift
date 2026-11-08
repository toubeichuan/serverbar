import XCTest
@testable import GPUMonitor

final class DiskTelemetryTests: XCTestCase {
    private func sample(uptime: String = "100", first: Int = 100, second: Int = 200) throws -> HostTelemetry {
        try XCTUnwrap(SnapshotParser.parse("""
        __GM_UPTIME__
        \(uptime) 0
        __GM_DISK__
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/nvme0n1p5 250000000 200000000 35000000 85% /
        /dev/nvme0n1p4 300000 40000 260000 13% /boot/efi
        /dev/nvme1n1p1 1900000000 200000000 1600000000 12% /data sets
        tmpfs 300000 0 300000 0% /run
        /dev/loop0 1000 1000 0 100% /snap
        /dev/nvme1n1p1 1900000000 200000000 1600000000 12% /data sets
        __GM_DISK_IO__
        nvme0n1 10 0 \(first) 0 10 0 \(second) 0 0 0 0
        nvme1n1 10 0 \(second) 0 10 0 \(first) 0 0 0 0
        __GM_DISK_SIZE__
        nvme0n1 2000000000
        nvme1n1 4000000000
        """).telemetry)
    }
    func testMultipleVolumesAndWholeDriveCapacity() throws {
        let t = try sample()
        XCTAssertEqual(t.volumes.count, 3)
        XCTAssertEqual(t.volumes.last?.mount, "/data sets")
        XCTAssertEqual(t.diskMount, "/")
        XCTAssertEqual(t.diskTotalKiB, 250000000)
        XCTAssertEqual(t.disks.count, 2)
        XCTAssertEqual(t.disks[0].capacityBytes, 2000000000 * 512)
        XCTAssertNil(t.diskReadRate)
    }
    func testSectorDeltasBecomeBytesPerSecond() throws {
        let old = try sample()
        var next = try sample(uptime: "110", first: 120, second: 240)
        next.calculateRates(previous: old)
        XCTAssertEqual(next.disks[0].readRate, 1024)
        XCTAssertEqual(next.disks[0].writeRate, 2048)
        XCTAssertEqual(next.diskReadRate, 3072)
        XCTAssertEqual(next.diskWriteRate, 3072)
    }
    func testResetRebootAndNewDiskAreUnknownNotFalseZero() throws {
        let old = try sample()
        var reset = try sample(uptime: "110", first: 1, second: 2)
        reset.calculateRates(previous: old)
        XCTAssertNil(reset.diskReadRate)
        var reboot = try sample(uptime: "1", first: 150, second: 250)
        reboot.calculateRates(previous: old)
        XCTAssertNil(reboot.diskReadRate)
        var newDisk = try sample(uptime: "110", first: 150, second: 250)
        var previous = old; previous.disks.removeLast()
        newDisk.calculateRates(previous: previous)
        XCTAssertNotNil(newDisk.disks[0].readRate)
        XCTAssertNil(newDisk.diskReadRate)
    }
    func testDiskProbeSyntaxAndLayerFiltering() async throws {
        let probe = SSHClient.probe(kind: .auto, panels: [.disk])
        let result = try await CommandRunner.run(executable: "/bin/sh", arguments: ["-n", "-c", probe])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(probe.contains("df -Pkl"))
        XCTAssertTrue(probe.contains("/slaves/*"))
        XCTAssertTrue(probe.contains("loop*|ram*|zram*|sr*"))
        XCTAssertFalse(probe.contains("nvidia-smi"))
    }
}
