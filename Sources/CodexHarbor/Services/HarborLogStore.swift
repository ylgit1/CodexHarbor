import Foundation

struct HarborLogStore {
    private let storageKey: String
    private let maximumEntries: Int

    init(
        storageKey: String = "codex-harbor.run-logs",
        maximumEntries: Int = 200
    ) {
        self.storageKey = storageKey
        self.maximumEntries = maximumEntries
    }

    func load() -> [HarborLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let logs = try? JSONDecoder().decode([HarborLogEntry].self, from: data) else {
            return []
        }
        return Array(logs.suffix(maximumEntries))
    }

    func save(_ logs: [HarborLogEntry]) {
        let trimmed = Array(logs.suffix(maximumEntries))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
