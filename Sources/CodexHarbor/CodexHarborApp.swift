import CodexHarborCore
import Foundation
import SwiftUI

@main
struct CodexHarborApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.dropFirst().first == "print-token" {
            do {
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
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 800, minHeight: 650)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 860, height: 680)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
