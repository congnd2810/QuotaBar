// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DeskAppCore"),
        .executableTarget(name: "DeskApp", dependencies: ["DeskAppCore"]),
        .testTarget(name: "DeskAppCoreTests", dependencies: ["DeskAppCore"]),
    ]
)
