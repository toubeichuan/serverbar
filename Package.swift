// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ServerBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ServerBar", targets: ["GPUMonitor"])],
    targets: [
        .executableTarget(name: "GPUMonitor"),
        .testTarget(name: "GPUMonitorTests", dependencies: ["GPUMonitor"])
    ],
    swiftLanguageModes: [.v5]
)
