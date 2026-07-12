import Foundation

public final class AppLogger {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public let fileURL: URL
    private let lock = NSLock()
    private let maxBytes: UInt64
    private let backupCount: Int
    private let fileManager: FileManager
    private let formatter: DateFormatter

    public init(
        fileURL: URL = AppPaths.standard.logFile,
        maxBytes: UInt64 = 1_000_000,
        backupCount: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.backupCount = backupCount
        self.fileManager = fileManager
        self.formatter = DateFormatter()
        self.formatter.locale = Locale(identifier: "en_US_POSIX")
        self.formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func info(_ message: String, password: String? = nil) {
        write(.info, message, password: password)
    }

    public func warning(_ message: String, password: String? = nil) {
        write(.warning, message, password: password)
    }

    public func error(_ message: String, password: String? = nil) {
        write(.error, message, password: password)
    }

    public func tail(maxLines: Int = 80) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .joined(separator: "\n")
    }

    public static func redact(_ input: String, password: String? = nil) -> String {
        var result = input
        if let password, !password.isEmpty {
            result = result.replacingOccurrences(of: password, with: "***")
        }

        let patterns = [
            #"(?i)(user_password\s*[=:]\s*)[^&\s)\"']+"#,
            #"(?i)(password\s*[=:]\s*)[^&\s)\"']+"#,
            #"(?i)(user_account\s*[=:]\s*)[^&\s)\"']+"#,
            #"(?i)https?://[^\s)]*/eportal/portal/login\?[^\s)]+"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = index == patterns.count - 1 ? "[login_url_redacted]" : "$1***"
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result
    }

    private func write(_ level: Level, _ message: String, password: String?) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rotateIfNeeded()
            let safeMessage = Self.redact(message.replacingOccurrences(of: "\n", with: " "), password: password)
            let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(safeMessage)\n"
            let data = Data(line.utf8)
            if !fileManager.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never prevent the menu-bar app from functioning.
        }
    }

    private func rotateIfNeeded() throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maxBytes else {
            return
        }
        if backupCount > 0 {
            for index in stride(from: backupCount, through: 1, by: -1) {
                let destination = URL(fileURLWithPath: "\(fileURL.path).\(index)")
                let source = index == 1
                    ? fileURL
                    : URL(fileURLWithPath: "\(fileURL.path).\(index - 1)")
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        } else {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
