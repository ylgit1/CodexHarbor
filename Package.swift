// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexHarbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexHarborCore", targets: ["CodexHarborCore"]),
        .executable(name: "CodexHarbor", targets: ["CodexHarbor"])
    ],
    targets: [
        .target(
            name: "CodexHarborCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CodexHarbor",
            dependencies: ["CodexHarborCore"]
        ),
        .testTarget(
            name: "CodexHarborCoreTests",
            dependencies: ["CodexHarborCore"]
        )
    ]
)
