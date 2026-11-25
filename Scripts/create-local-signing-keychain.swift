#!/usr/bin/swift
import Foundation
import Security
import Darwin

// Creates only a NEW, private generation in the application's signing area.
// No existing keychain, default keychain, or password is modified.
func fail(_ stage: String, _ status: OSStatus = -1) -> Never {
    FileHandle.standardError.write(Data(("Signing generation: " + stage + " (" + String(status) + ")\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("missing generation directory") }
let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexHarbor/CodeSigning")
let generation = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
var info = stat()
guard generation.deletingLastPathComponent().path == root.path,
      generation.lastPathComponent.hasPrefix("generation-"),
      UUID(uuidString: String(generation.lastPathComponent.dropFirst("generation-".count))) != nil,
      lstat(generation.path, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0
else { fail("invalid generation directory") }

func privateData(_ name: String) throws -> Data {
    let path = generation.appendingPathComponent(name).path
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { fail("cannot open private input") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == geteuid(),
          (st.st_mode & S_IFMT) == S_IFREG, (st.st_mode & 0o077) == 0,
          st.st_nlink == 1, st.st_size > 0, st.st_size <= 1024 * 1024 else { fail("unsafe private input") }
    return try handle.readToEnd() ?? Data()
}
do {
    let keychainURL = generation.appendingPathComponent("signing.keychain-db")
    guard !FileManager.default.fileExists(atPath: keychainURL.path) else { fail("keychain already exists") }
    guard let password = String(data: try privateData("keychain.password"), encoding: .utf8),
          let importPassword = String(data: try privateData("import.password"), encoding: .utf8),
          !password.isEmpty, !importPassword.isEmpty else { fail("invalid private input") }
    let p12 = try privateData("identity.p12")
    SecKeychainSetUserInteractionAllowed(false)
    var keychain: SecKeychain?
    let created = password.withCString {
        SecKeychainCreate(keychainURL.path, UInt32(password.utf8.count), $0, false, nil, &keychain)
    }
    guard created == errSecSuccess, let keychain else { fail("create keychain", created) }
    var trustedApp: SecTrustedApplication?
    let trusted = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trustedApp)
    guard trusted == errSecSuccess, let trustedApp else { fail("trusted codesign application", trusted) }
    var access: SecAccess?
    let accessStatus = SecAccessCreate("Codex Harbor local signing" as CFString, [trustedApp] as CFArray, &access)
    guard accessStatus == errSecSuccess, let access else { fail("create key access", accessStatus) }
    let options: [String: Any] = [
        kSecImportExportPassphrase as String: importPassword,
        kSecImportExportKeychain as String: keychain,
        kSecImportExportAccess as String: access
    ]
    var imported: CFArray?
    let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &imported)
    guard status == errSecSuccess else { fail("import signing identity", status) }

    // Prove that the exact persisted password can reopen this keychain after
    // it has been locked. Do not activate a generation that only works while
    // its creation session happens to leave the keychain unlocked.
    let lockStatus = SecKeychainLock(keychain)
    guard lockStatus == errSecSuccess else { fail("lock keychain for persistence check", lockStatus) }
    var reopened: SecKeychain?
    let openStatus = SecKeychainOpen(keychainURL.path, &reopened)
    guard openStatus == errSecSuccess, let reopened else { fail("reopen keychain", openStatus) }
    let unlockStatus = password.withCString {
        SecKeychainUnlock(reopened, UInt32(password.utf8.count), $0, true)
    }
    guard unlockStatus == errSecSuccess else { fail("stored password persistence check", unlockStatus) }

    var search: CFArray?
    let listed = SecKeychainCopySearchList(&search)
    guard listed == errSecSuccess, let existing = search as? [SecKeychain] else { fail("read search list", listed) }
    // Preserve every existing keychain; never change the default.
    let update = SecKeychainSetSearchList((existing + [keychain]) as CFArray)
    guard update == errSecSuccess else { fail("append new keychain", update) }
    print("New dedicated keychain and signing identity created")
} catch {
    fail("private input or keychain operation failed")
}
