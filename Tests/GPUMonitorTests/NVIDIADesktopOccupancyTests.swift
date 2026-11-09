import XCTest
@testable import GPUMonitor

final class NVIDIADesktopOccupancyTests: XCTestCase {
    private func sample(rows: String = "0 101 G 645 0 Xorg\n0 102 G 18 0 gnome-shell",
                        used: Int = 837, utilization: Int = 0, apps: String = "",
                        graphicsOK: Bool = true, appsOK: Bool = true) throws -> Accelerator {
        let raw = """
        __GM_GPU__
        0, GPU-test, NVIDIA GeForce RTX 3080 Ti, \(utilization), \(used), 12288, 40
        __GM_APPS__
        \(apps)
        \(appsOK ? "__GM_APPS_OK__" : "")
        __GM_GRAPHICS__
        # gpu pid type fb ccpm command
        \(rows)
        \(graphicsOK ? "__GM_GRAPHICS_OK__" : "")
        __GM_PS__
        101 desktop Xorg
        102 desktop gnome-shell
        __GM_PS_OK__
        """
        return try XCTUnwrap(SnapshotParser.parse(raw).devices.first)
    }

    func testDesktopMemoryIsNotAComputeTaskAndDisplayKeepsRealTotal() throws {
        let device = try sample()
        XCTAssertEqual(device.state, .idle)
        XCTAssertEqual(device.memoryUsedMiB, 837)
        XCTAssertEqual(device.desktopMemoryMiB, 663)
        XCTAssertEqual(device.occupancyMemoryMiB, 174)
        XCTAssertTrue(device.occupancyReason.contains("桌面"))
    }

    func testSmallComputeTaskAndHighLoadStillMeanOccupied() throws {
        XCTAssertEqual(try sample(apps: "GPU-test, 200, python, 20").state, .occupied)
        XCTAssertEqual(try sample(utilization: 5).state, .busy)
        XCTAssertNotEqual(try sample(appsOK: false).state, .idle)
        XCTAssertNotEqual(try sample(apps: "malformed").state, .idle)
    }

    func testNeverExemptsUnknownGraphicsOrMixedComputeContexts() throws {
        for row in ["0 101 G 800 0 game", "0 101 G 800 0 chrome", "0 101 C+G 800 0 Xorg",
                    "0 101 C 800 0 Xorg", "0 101 M 800 0 Xorg", "0 101 G - 0 Xorg"] {
            let device = try sample(rows: row)
            XCTAssertEqual(device.desktopMemoryMiB, 0, row)
            XCTAssertEqual(device.state, .occupied, row)
        }
        XCTAssertEqual(try sample(apps: "GPU-test, 101, Xorg, 645").desktopMemoryMiB, 18)
    }

    func testUnsupportedProbeAndUnattributedLargeAllocationsStayConservative() throws {
        XCTAssertEqual(try sample(graphicsOK: false).desktopMemoryMiB, 0)
        XCTAssertEqual(try sample(graphicsOK: false).state, .occupied)
        XCTAssertEqual(try sample(used: 4096).state, .occupied)
        XCTAssertEqual(try sample(rows: "not a pmon row").state, .occupied)
        XCTAssertEqual(try sample(rows: "1 101 G 800 0 Xorg").desktopMemoryMiB, 0)
    }

    func testPmonOlderFormatAndDuplicateRowsDoNotInflateExemption() throws {
        let device = try sample(rows: "0 101 G 645 Xorg\n0 101 G 645 Xorg")
        XCTAssertEqual(device.desktopMemoryMiB, 645)
        XCTAssertEqual(device.state, .idle)
    }

    @MainActor func testSummaryAndMenuUseCorrectedAvailability() throws {
        let store = MonitorStore(configURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), startPolling: false)
        let server = Server(name: "test", host: "test")
        store.servers = [server]
        store.statuses[server.id] = ServerStatus(snapshot: Snapshot(devices: [try sample()]))
        XCTAssertEqual(store.menuTitle, "1/1")
        XCTAssertEqual(store.summary().occupied, 0)
    }
}
