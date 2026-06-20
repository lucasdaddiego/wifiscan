// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wifiscan",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "wifiscan",
            path: "Sources/wifiscan"
        )
    ]
)
