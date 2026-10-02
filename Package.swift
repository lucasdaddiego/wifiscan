// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "wifiscan",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "wifiscan")
    ]
)
