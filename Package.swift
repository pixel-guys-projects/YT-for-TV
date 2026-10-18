// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "YT for TV",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .executable(name: "YT for TV", targets: ["AppModule"])
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        )
    ]
)
