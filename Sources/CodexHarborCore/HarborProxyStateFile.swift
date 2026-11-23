import CryptoKit
import Darwin
import Foundation

/// Encrypted proxy preferences are writable only after the existing state has
/// been read successfully. A missing file is distinct from a denied read.
public actor HarborProxyStateFile<State: Codable & Sendable> {
    private let url: URL
    private let emptyState: State
    private let legacyState: @Sendable () throws -> State?
    private let keyProvider: @Sendable (_ create: Bool) throws -> SymmetricKey
    private let sizeLimit = 32 * 1_024 * 1_024
    private var loaded = false
    private var newestGeneration = 0
    private var key: SymmetricKey?

    public init(url: URL, emptyState: State,
                legacyState: @escaping @Sendable () throws -> State?,
                keyProvider: @escaping @Sendable (Bool) throws -> SymmetricKey) {
        self.url = url
        self.emptyState = emptyState
        self.legacyState = legacyState
        self.keyProvider = keyProvider
    }

    public func load() throws -> State {
        loaded = false
        let data: Data
        do { data = try readFile(at: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            let legacy = try legacyState()
            if let legacy { try write(legacy) }
            loaded = true
            return legacy ?? emptyState
        }
        let state = try decrypt(data)
        loaded = true
        return state
    }

    public func save(_ state: State, generation: Int) throws {
        guard loaded else { throw HarborProxyError.invalid("原代理配置尚未读取，已保护原文件") }
        guard generation >= newestGeneration else { return }
        try write(state)
        newestGeneration = generation
    }

    private func readFile(at path: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: sizeLimit + 1), data.count <= sizeLimit else {
            throw HarborProxyError.invalid("代理配置为空或超过大小限制，原文件已保留")
        }
        return data
    }

    private func keyForFile(create: Bool) throws -> SymmetricKey {
        if let key { return key }
        let loaded = try keyProvider(create)
        key = loaded
        return loaded
    }

    private func decrypt(_ data: Data) throws -> State {
        let key = try keyForFile(create: false)
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let bytes = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(State.self, from: bytes)
        } catch {
            throw HarborProxyError.invalid("代理配置无法解密或解码，原文件已保留")
        }
    }

    private func write(_ state: State) throws {
        let encoded = try JSONEncoder().encode(state)
        guard encoded.count < sizeLimit - 256 else {
            throw HarborProxyError.invalid("代理配置超过大小限制，原文件已保留")
        }
        let key = try keyForFile(create: true)
        guard let encrypted = try AES.GCM.seal(encoded, using: key).combined else {
            throw HarborProxyError.invalid("无法加密代理配置")
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staged = parent.appendingPathComponent(".settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HarborProxyError.invalid("无法创建私有代理配置文件")
        }
        try encrypted.write(to: staged, options: .completeFileProtection)
        _ = try decrypt(readFile(at: staged))
        guard Darwin.rename(staged.path, url.path) == 0 else {
            throw HarborProxyError.invalid("代理配置无法保存，原文件已保留")
        }
    }
}
