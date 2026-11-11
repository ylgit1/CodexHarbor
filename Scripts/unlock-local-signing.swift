#!/usr/bin/swift
import Foundation
import Security
import Darwin

// Unlock only Harbor's dedicated signing keychain. The random local password
// stays in a user-only file and is never passed as a command argument.
struct SigningProfile: Decodable {
    let identity: String
    let keychainPath: String
    let passwordPath: String
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
do {
    guard CommandLine.arguments.count == 2 else {
        fail("缺少本地签名配置，已停止打包")
    }
    let profileURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let profile = try JSONDecoder().decode(
        SigningProfile.self, from: Data(contentsOf: profileURL))
    let directory = profileURL.deletingLastPathComponent()
    guard profile.identity.range(of: "^[A-Fa-f0-9]{40}$",
                                 options: .regularExpression) != nil,
          profile.keychainPath == directory.appendingPathComponent("signing.keychain-db").path,
          profile.passwordPath == directory.appendingPathComponent("keychain.password").path,
          FileManager.default.fileExists(atPath: profile.keychainPath) else {
        fail("固定签名配置不完整，已停止打包；不会改用临时签名")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: profile.passwordPath)
    guard let owner = attributes[.ownerAccountID] as? NSNumber,
          owner.uint32Value == geteuid(),
          let mode = attributes[.posixPermissions] as? NSNumber,
          mode.intValue & 0o077 == 0 else {
        fail("签名凭据文件必须仅供当前用户读写，已停止打包")
    }
    let password = try String(contentsOfFile: profile.passwordPath, encoding: .utf8)
        .trimmingCharacters(in: .newlines)
    guard !password.isEmpty else { fail("签名凭据为空，已停止打包") }
    SecKeychainSetUserInteractionAllowed(false)
    var keychain: SecKeychain?
    let opened = SecKeychainOpen(profile.keychainPath, &keychain)
    guard opened == errSecSuccess, let keychain else {
        fail("无法打开专用签名钥匙串（\(opened)），已停止打包")
    }
    let status = password.withCString {
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true)
    }
    guard status == errSecSuccess else {
        fail("无法解锁专用签名钥匙串（\(status)），已停止打包")
    }
    // codesign requires the identity's keychain on the user's search list,
    // even with --keychain. Append ours without changing existing entries or
    // the default login keychain.
    var searchList: CFArray?
    guard SecKeychainCopySearchList(&searchList) == errSecSuccess,
          let entries = searchList as? [SecKeychain] else {
        fail("无法读取签名钥匙串列表，已停止打包")
    }
    let alreadyListed = entries.contains { entry in
        var length: UInt32 = 4096
        var bytes = [CChar](repeating: 0, count: Int(length))
        let result = SecKeychainGetPath(entry, &length, &bytes)
        return result == errSecSuccess
            && String(cString: bytes) == profile.keychainPath
    }
    if !alreadyListed {
        guard SecKeychainSetSearchList((entries + [keychain]) as CFArray) == errSecSuccess else {
            fail("无法启用专用签名钥匙串，已停止打包")
        }
    }
} catch {
    fail("无法读取本地签名配置，已停止打包；不会改用临时签名")
}
