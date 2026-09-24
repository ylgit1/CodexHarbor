import SwiftUI
import CodexHarborCore

/// Single coordinator for the desktop window. It owns no duplicate model;
/// `AppShellView` receives the instance created by `CodexHarborApp` and owns
/// only window-level navigation and presentation coordination.
struct RootViewCoordinator: View {
    @ObservedObject var model: AppModel

    var body: some View {
        AppShellView(model: model)
            .frame(minWidth: 1024, minHeight: 640)
    }
}
