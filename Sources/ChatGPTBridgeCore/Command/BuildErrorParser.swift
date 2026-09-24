import Foundation

public struct BuildError: Codable, Equatable, Sendable {
    public let file: String
    public let line: Int
    public let column: Int
    public let message: String

    public init(file: String, line: Int, column: Int, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
    }
}

public struct BuildErrorParser: Sendable {
    public init() {}

    public func parse(_ output: String) -> [BuildError] {
        let pattern = #"^(.+\.swift):(\d+):(\d+):?\s+error:\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            guard let fileRange = Range(match.range(at: 1), in: output),
                  let lineRange = Range(match.range(at: 2), in: output),
                  let columnRange = Range(match.range(at: 3), in: output),
                  let messageRange = Range(match.range(at: 4), in: output),
                  let line = Int(output[lineRange]),
                  let column = Int(output[columnRange]) else { return nil }
            return BuildError(
                file: String(output[fileRange]),
                line: line,
                column: column,
                message: String(output[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
