import SwiftUI
import CodexHarborCore

/// Top-level application route.
///
/// The feature implementation is split into page-sized views under `Views/`.
/// Keeping this shell deliberately small makes the app entry point stable and
/// prevents navigation state from being recreated by child pages.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RootViewCoordinator(model: model)
    }
}
