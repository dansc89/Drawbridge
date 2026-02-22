// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Drawbridge",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Drawbridge"
        ),
        .testTarget(
            name: "DrawbridgeTests",
            dependencies: ["Drawbridge"]
        )
    ]
)
