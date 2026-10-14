// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacBright",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacBright", path: "Sources/MacBright")
    ]
)
