import ChatGPTBridgeCore
import Foundation

/// Lightweight, read-only checks of runtime dependencies. Called once on launch
/// and whenever Settings is opened; never downloads or changes system settings.
@MainActor
final class HarborRuntimeEnvironment: ObservableObject {
    static let shared = HarborRuntimeEnvironment()
    @Published private(set) var chatGPTDesktop = false
    @Published private(set) var tunnelClient = false
    @Published private(set) var cloudflared = false
    @Published private(set) var xray = false
    @Published private(set) var git = false

    private init() {}

    func refresh() {
        let applications = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app", isDirectory: true)
        ]
        chatGPTDesktop = applications.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/ChatGPT").path)
        }
        git = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
        if let paths = try? BridgePaths.live() {
            let binaries = BridgeBinaryManager(paths: paths)
            tunnelClient = binaries.locateTunnelClient(preferredPath: nil) != nil
            cloudflared = binaries.locateCloudflared(preferredPath: nil) != nil
        } else {
            tunnelClient = false
            cloudflared = false
        }
        xray = HarborProxyManager.shared.coreInstalled
    }
}
