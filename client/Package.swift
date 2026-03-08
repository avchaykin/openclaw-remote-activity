// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenClawActivity",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenClawActivity",
            path: "Sources"
        )
    ]
)
