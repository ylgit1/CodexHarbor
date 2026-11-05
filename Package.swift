// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexHarbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexHarborCore", targets: ["CodexHarborCore"]),
        .library(name: "ChatGPTBridgeCore", targets: ["ChatGPTBridgeCore"]),
        .executable(name: "CodexHarbor", targets: ["CodexHarbor"]),
        .executable(name: "HarborChatGPTAgent", targets: ["HarborChatGPTAgent"]),
        .executable(name: "HarborUsageCardAgent", targets: ["HarborUsageCardAgent"])
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
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "CodexHarbor",
            dependencies: ["CodexHarborCore", "ChatGPTBridgeCore"],
            resources: [.process("Resources/ProxyFlags")]
        ),
        .executableTarget(
            name: "HarborChatGPTAgent",
            dependencies: ["ChatGPTBridgeCore"]
        ),
        .executableTarget(
            name: "HarborUsageCardAgent",
            dependencies: ["CodexHarborCore"]
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
