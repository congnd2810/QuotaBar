// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "QuotaBarCore"),
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaBarCore"]),
        .testTarget(name: "QuotaBarCoreTests", dependencies: ["QuotaBarCore"]),
    ]
)
