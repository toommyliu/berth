// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Berth",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Berth"),
        .testTarget(name: "BerthTests", dependencies: ["Berth"]),
    ]
)
