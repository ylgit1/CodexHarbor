// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexHarbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexHarborCore", targets: ["CodexHarborCore"]),
        .library(name: "ChatGPTBridgeCore", targets: ["ChatGPTBridgeCore"]),
        .executable(name: "CodexHarbor", targets: ["CodexHarbor"]),
        .executable(name: "HarborChatGPTAgent", targets: ["HarborChatGPTAgent"])
    ],
    targets: [
        .target(
            name: "CodexHarborCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ChatGPTBridgeCore",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CodexHarbor",
            dependencies: ["CodexHarborCore", "ChatGPTBridgeCore"]
        ),
        .executableTarget(
            name: "HarborChatGPTAgent",
            dependencies: ["ChatGPTBridgeCore"]
        ),
        .testTarget(
            name: "CodexHarborCoreTests",
            dependencies: ["CodexHarborCore"]
        ),
        .testTarget(
            name: "ChatGPTBridgeCoreTests",
            dependencies: ["ChatGPTBridgeCore"]
        )
    ]
)
