// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wisp",
            path: "Sources/Wisp",
            resources: []
        ),
    ]
)
