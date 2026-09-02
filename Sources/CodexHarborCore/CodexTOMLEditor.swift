import Foundation

struct CodexConfigurationSpec: Equatable, Sendable {
    static let provider = "codex_harbor"
    static let beginMarker = "# >>> CODEX HARBOR MANAGED CONFIG >>>"
    static let endMarker = "# <<< CODEX HARBOR MANAGED CONFIG <<<"

    let apiBaseURL: URL
    let model: String
    let helperExecutable: URL
    let modelCatalogURL: URL?

    init(apiBaseURL: URL, model: String, helperExecutable: URL, modelCatalogURL: URL? = nil) {
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.helperExecutable = helperExecutable
        self.modelCatalogURL = modelCatalogURL
    }
}

enum CodexTOMLEditor {
    private static let managedTopLevelKeys = ["model", "model_provider", "model_reasoning_effort", "model_catalog_json"]

    static func applying(
        to original: String,
        spec: CodexConfigurationSpec
    ) throws -> String {
        guard spec.apiBaseURL.scheme?.lowercased() == "https" else { throw HarborError.invalidBaseURL }
        guard isSafeModel(spec.model) else { throw HarborError.invalidModel }

        let removal = removeManagedBlock(from: normalized(original))
        if !removal.didRemove && containsReservedNamespace(removal.text) {
            throw HarborError.existingManagedNamespace
        }

        var updated = setTopLevelString(key: "model", value: spec.model, in: removal.text)
        updated = setTopLevelString(key: "model_provider", value: CodexConfigurationSpec.provider, in: updated)
        updated = setTopLevelString(key: "model_reasoning_effort", value: "high", in: updated)
        if let modelCatalogURL = spec.modelCatalogURL {
            updated = setTopLevelString(key: "model_catalog_json", value: modelCatalogURL.path, in: updated)
        } else {
            updated = removeTopLevelAssignment(key: "model_catalog_json", from: updated)
        }
        updated = updated.trimmingCharacters(in: .newlines)
        if !updated.isEmpty { updated += "\n\n" }
        updated += managedBlock(spec: spec)
        updated += "\n"
        try validate(updated, expectedModel: spec.model)
        return updated
    }

    static func validate(_ configuration: String, expectedModel: String) throws {
        guard topLevelString(key: "model_provider", in: configuration) == CodexConfigurationSpec.provider else {
            throw HarborError.invalidConfiguration("模型服务商未生效")
        }
        guard topLevelString(key: "model", in: configuration) == expectedModel else {
            throw HarborError.invalidConfiguration("模型未生效")
        }
        let required = [
            CodexConfigurationSpec.beginMarker,
            "[model_providers.\(CodexConfigurationSpec.provider)]",
            "wire_api = \"responses\"",
            "[model_providers.\(CodexConfigurationSpec.provider).auth]",
            CodexConfigurationSpec.endMarker
        ]
        guard required.allSatisfy(configuration.contains) else {
            throw HarborError.invalidConfiguration("托管配置块不完整")
        }
        guard configuration.components(separatedBy: CodexConfigurationSpec.beginMarker).count == 2,
              configuration.components(separatedBy: CodexConfigurationSpec.endMarker).count == 2 else {
            throw HarborError.invalidConfiguration("检测到重复的托管配置块")
        }
    }

    /// Returns a stable representation for deciding whether a Codex
    /// configuration's effective content changed. Codex and other tools may
    /// rewrite line endings, indentation, blank lines, or comments while
    /// preserving the same TOML values. Those file-level changes do not
    /// require Codex to be reloaded, so startup reconciliation compares this
    /// representation instead of raw file bytes.
    static func semanticFingerprint(_ configuration: String) -> String {
        normalized(configuration)
            .components(separatedBy: "\n")
            .compactMap(canonicalLine)
            .joined(separator: "\n")
    }

    static func restoringAccountConfiguration(in configuration: String, original: String) throws -> String {
        let normalizedConfiguration = normalized(configuration)
        let removal = removeManagedBlock(from: normalizedConfiguration)
        if !removal.didRemove {
            let hasBeginMarker = normalizedConfiguration.contains(CodexConfigurationSpec.beginMarker)
            let hasEndMarker = normalizedConfiguration.contains(CodexConfigurationSpec.endMarker)
            guard !hasBeginMarker,
                  !hasEndMarker,
                  !containsReservedNamespace(normalizedConfiguration) else {
                throw HarborError.invalidConfiguration("Harbor 托管配置块不完整")
            }
        }
        var restored = removal.text
        for key in managedTopLevelKeys {
            restored = restoreTopLevelAssignment(key: key, from: normalized(original), in: restored)
        }
        return restored.trimmingCharacters(in: .newlines) + "\n"
    }

    /// Selects the account provider for new turns while keeping Harbor's provider
    /// definition available. Existing Codex sessions remember the provider they
    /// were created with, so removing this block during a mode switch makes older
    /// Harbor sessions impossible to resume.
    static func selectingAccountConfiguration(in configuration: String, original: String) throws -> String {
        let normalizedConfiguration = normalized(configuration)
        try validateManagedBlock(normalizedConfiguration)
        var selected = normalizedConfiguration
        for key in managedTopLevelKeys {
            selected = restoreTopLevelAssignment(key: key, from: normalized(original), in: selected)
        }
        return selected.trimmingCharacters(in: .newlines) + "\n"
    }

    static func accountBaseline(from configuration: String) throws -> String {
        let normalizedConfiguration = normalized(configuration)
        let removal = removeManagedBlock(from: normalizedConfiguration)
        if !removal.didRemove {
            let hasBeginMarker = normalizedConfiguration.contains(CodexConfigurationSpec.beginMarker)
            let hasEndMarker = normalizedConfiguration.contains(CodexConfigurationSpec.endMarker)
            guard !hasBeginMarker, !hasEndMarker, !containsReservedNamespace(normalizedConfiguration) else {
                throw HarborError.invalidConfiguration("Harbor 托管配置块不完整")
            }
        }
        return removal.text.trimmingCharacters(in: .newlines) + "\n"
    }

    static func topLevelString(key: String, in source: String) -> String? {
        let lines = normalized(source).components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            let rhs = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard rhs.first == "\"", let closing = rhs.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(rhs[rhs.index(after: rhs.startIndex)..<closing])
        }
        return nil
    }

    static func string(key: String, inTable table: String, source: String) -> String? {
        var isInTargetTable = false
        for line in normalized(source).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isInTargetTable = trimmed == "[\(table)]"
                continue
            }
            guard isInTargetTable,
                  !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let lhs = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            let rhs = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard rhs.first == "\"", let closing = rhs.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(rhs[rhs.index(after: rhs.startIndex)..<closing])
        }
        return nil
    }

    private static func setTopLevelString(key: String, value: String, in source: String) -> String {
        var lines = normalized(source).components(separatedBy: "\n")
        let replacement = "\(key) = \(quoted(value))"
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        for index in 0..<firstTable {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key {
                lines[index] = replacement
                return lines.joined(separator: "\n")
            }
        }
        var insertion = firstTable
        while insertion > 0 && lines[insertion - 1].isEmpty { insertion -= 1 }
        lines.insert(replacement, at: insertion)
        if insertion + 1 < lines.count, !lines[insertion + 1].isEmpty {
            lines.insert("", at: insertion + 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func removeTopLevelAssignment(key: String, from source: String) -> String {
        var lines = normalized(source).components(separatedBy: "\n")
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        if let index = (0..<firstTable).first(where: { assignmentKey(in: lines[$0]) == key }) {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    private static func restoreTopLevelAssignment(key: String, from original: String, in source: String) -> String {
        var lines = normalized(source).components(separatedBy: "\n")
        let originalLine = topLevelAssignmentLine(key: key, in: original)
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        if let index = (0..<firstTable).first(where: { assignmentKey(in: lines[$0]) == key }) {
            if let originalLine {
                lines[index] = originalLine
            } else {
                lines.remove(at: index)
            }
        } else if let originalLine {
            var insertion = firstTable
            while insertion > 0 && lines[insertion - 1].isEmpty { insertion -= 1 }
            lines.insert(originalLine, at: insertion)
            if insertion + 1 < lines.count, !lines[insertion + 1].isEmpty {
                lines.insert("", at: insertion + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func topLevelAssignmentLine(key: String, in source: String) -> String? {
        for line in normalized(source).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            if assignmentKey(in: line) == key { return line }
        }
        return nil
    }

    private static func assignmentKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[..<equals].trimmingCharacters(in: .whitespaces))
    }

    private static func removeManagedBlock(from source: String) -> (text: String, didRemove: Bool) {
        guard let start = source.range(of: CodexConfigurationSpec.beginMarker),
              let end = source.range(of: CodexConfigurationSpec.endMarker, range: start.upperBound..<source.endIndex) else {
            return (source, false)
        }
        var range = start.lowerBound..<end.upperBound
        if range.upperBound < source.endIndex, source[range.upperBound] == "\n" {
            range = range.lowerBound..<source.index(after: range.upperBound)
        }
        var result = source
        result.removeSubrange(range)
        return (result, true)
    }

    private static func containsReservedNamespace(_ source: String) -> Bool {
        let reserved = [
            "[model_providers.\(CodexConfigurationSpec.provider)]"
        ]
        return reserved.contains { source.contains($0) }
    }

    private static func validateManagedBlock(_ configuration: String) throws {
        let required = [
            CodexConfigurationSpec.beginMarker,
            "[model_providers.\(CodexConfigurationSpec.provider)]",
            "[model_providers.\(CodexConfigurationSpec.provider).auth]",
            CodexConfigurationSpec.endMarker
        ]
        guard required.allSatisfy(configuration.contains),
              configuration.components(separatedBy: CodexConfigurationSpec.beginMarker).count == 2,
              configuration.components(separatedBy: CodexConfigurationSpec.endMarker).count == 2 else {
            throw HarborError.invalidConfiguration("Harbor 托管配置块不完整")
        }
    }

    private static func managedBlock(spec: CodexConfigurationSpec) -> String {
        [
            CodexConfigurationSpec.beginMarker,
            "# 此区域由 Codex Harbor 管理。请通过应用切换或卸载。",
            "[model_providers.\(CodexConfigurationSpec.provider)]",
            "name = \"Codex Harbor\"",
            "base_url = \(quoted(spec.apiBaseURL.absoluteString))",
            "wire_api = \"responses\"",
            "",
            "[model_providers.\(CodexConfigurationSpec.provider).auth]",
            "command = \(quoted(spec.helperExecutable.path))",
            "args = [\"print-token\"]",
            "timeout_ms = 5000",
            // Keep cross-process caching, but make key changes effective quickly.
            // A zero interval refreshes only after a 401, which would retain a
            // stale key until the first failed request.
            "refresh_interval_ms = 1000",
            CodexConfigurationSpec.endMarker
        ].joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func canonicalLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var result = String()
        result.reserveCapacity(trimmed.count)
        var inDoubleQuotes = false
        var inSingleQuotes = false
        var escaped = false

        for character in trimmed {
            if inDoubleQuotes {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inDoubleQuotes = false
                }
                continue
            }
            if inSingleQuotes {
                result.append(character)
                if character == "'" { inSingleQuotes = false }
                continue
            }
            if character == "\"" {
                inDoubleQuotes = true
                result.append(character)
            } else if character == "'" {
                inSingleQuotes = true
                result.append(character)
            } else if character == "#" {
                // TOML comments extend to the end of the line. A hash inside
                // a quoted value was handled above and is retained.
                break
            } else if !character.isWhitespace {
                result.append(character)
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func isSafeModel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/")).contains($0)
        }
    }
}
