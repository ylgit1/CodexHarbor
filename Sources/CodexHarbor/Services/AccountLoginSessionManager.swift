import CodexHarborCore
import Darwin
import Foundation

@MainActor
final class AccountLoginSessionManager {
    private var process: Process?
    private var loginHomeURL: URL?
    private(set) var previousAccountID: UUID?

    var isActive: Bool {
        process?.isRunning == true || loginHomeURL != nil
    }

    func start(previousAccountID: UUID?) throws {
        guard !isActive else { return }

        let executable = try CodexProcessSupport.executableURL()
        let loginHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarbor-Login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: true)

        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
            var environment = CodexProcessSupport.environment()
            environment["CODEX_HOME"] = loginHome.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            self.process = process
            self.loginHomeURL = loginHome
            self.previousAccountID = previousAccountID
        } catch {
            try? FileManager.default.removeItem(at: loginHome)
            throw error
        }
    }

    func authenticationData() throws -> Data {
        guard let loginHomeURL else {
            throw HarborError.invalidConfiguration("隔离登录环境不存在，请重新开始添加账户")
        }
        let authenticationURL = loginHomeURL.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authenticationURL.path) else {
            throw HarborError.invalidConfiguration("尚未检测到登录完成，请在浏览器完成授权后重试")
        }
        return try Data(contentsOf: authenticationURL)
    }

    func finish() async {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<8 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process = nil

        if let loginHomeURL {
            try? FileManager.default.removeItem(at: loginHomeURL)
        }
        loginHomeURL = nil
        previousAccountID = nil
    }
}
