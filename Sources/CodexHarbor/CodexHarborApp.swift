import CodexHarborCore
import Foundation
import SwiftUI

@main
struct CodexHarborApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.dropFirst().first == "serve-relay" {
            do {
                let server = HarborRelayServer()
                try server.start()
                withExtendedLifetime(server) { RunLoop.current.run() }
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        if CommandLine.arguments.dropFirst().first == "print-token" {
            do {
                let paths = CodexPaths.live()
                if HarborRelayProcess.shouldRun(paths: paths) {
                    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
                    try? HarborRelayProcess.ensureRunning(executable: executable, paths: paths)
                }
                let store = LocalSecretStore.liveMigratingLegacyKeychain()
                guard let token = try store.string(for: .apiToken), !token.isEmpty else {
                    throw HarborError.missingToken
                }
                FileHandle.standardOutput.write(Data(token.utf8))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Codex Harbor", id: "main") {
            RootView(model: model)
                // Match the adaptive shell's minimum without forcing a tall
                // window that crowds the trend and health sections.
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label("Codex Harbor", systemImage: model.environment.activeMode == nil ? "circle.dashed" : "point.3.connected.trianglepath.dotted")
        }
        .menuBarExtraStyle(.menu)
    }
}
