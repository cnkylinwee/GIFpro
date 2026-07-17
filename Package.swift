// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "GIFpro",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "GIFpro"),
        .testTarget(
            name: "GIFproTests",
            dependencies: ["GIFpro"]
        ),
        .testTarget(
            name: "GIFproIntegrationTests",
            dependencies: ["GIFpro"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
