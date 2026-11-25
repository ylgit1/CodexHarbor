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
        .executable(name: "HarborUsageCardAgent", targets: ["HarborUsageCardAgent"]),
        .executable(name: "HarborProxyAgent", targets: ["HarborProxyAgent"]),
        .executable(name: "HarborProxySelfTest", targets: ["HarborProxySelfTest"]),
        .executable(name: "HarborProxyIPCFixture", targets: ["HarborProxyIPCFixture"])
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
        .target(
            name: "HarborProxyRuntime",
            dependencies: ["CodexHarborCore"],
            linkerSettings: [.linkedFramework("Network"), .linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "HarborProxyAgent",
            dependencies: ["CodexHarborCore", "HarborProxyRuntime"]
        ),
        .executableTarget(name: "HarborProxyIPCFixture", dependencies: ["HarborProxyRuntime", "CodexHarborCore"], path: "Tests/ProxyIPCFixture"),
        .target(name: "HarborProxyTestSupport", dependencies: ["CodexHarborCore"], path: "Tests/ProxyTestSupport"),
        .executableTarget(name: "HarborProxySelfTest", dependencies: ["HarborProxyTestSupport"], path: "Tests/ProxySelfTest"),
        .testTarget(
            name: "CodexHarborCoreTests",
            dependencies: ["CodexHarborCore", "HarborProxyTestSupport", "HarborProxyRuntime"]
        ),
        .testTarget(
            name: "ChatGPTBridgeCoreTests",
            dependencies: ["ChatGPTBridgeCore"]
        )
    ]
)
