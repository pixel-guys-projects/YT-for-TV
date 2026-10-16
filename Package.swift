// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YTforTV_Playgrounds",
    platforms: [
        .iOS(.v17)  // Changed from .v26
    ],
    targets: [
        .executableTarget(
            name: "YTforTV_Playgrounds",
            dependencies: []
        )
    ]
)
