import Foundation

struct HarborLogEntry: Identifiable, Equatable, Codable {
    enum Level: String, Codable {
        case info
        case success
        case error
    }

    var id = UUID()
    let timeText: String
    let level: Level
    let message: String
}

struct ConnectionDiagnostic: Equatable {
    let checkedAt: Date
    let latencyMilliseconds: Int?
    let modelCount: Int?
    let failureReason: String?
}
