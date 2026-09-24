import CodexHarborCore
import Foundation

struct CodexRequestMonitorStateStore {
    private struct State: Codable {
        var observedTurnIDs: [String]
    }

    private let url: URL
    private let maximumIDs: Int

    init(
        url: URL = CodexPaths.live().requestMonitorStateURL,
        maximumIDs: Int = 2_000
    ) {
        self.url = url
        self.maximumIDs = maximumIDs
    }

    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return []
        }
        return Set(state.observedTurnIDs)
    }

    func save(_ ids: Set<String>) {
        let state = State(observedTurnIDs: Array(ids.suffix(maximumIDs)))
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
