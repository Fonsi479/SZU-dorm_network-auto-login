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
        var output = input
        let patterns: [(String, String)] = [
            (#"(?i)((?:challenge|info|chksum|checksum|ssid|source[_-]?ip)\s*[:=：]\s*)[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)\{(?:MD5|SRBX1)\}[^\s,;}&]+"#, "[REDACTED]"),
            (#"(?i)\b(https?://[^\s?]+)\?[^\s]+"#, "$1?[REDACTED]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[IP REDACTED]"),
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        for secret in password.map({ [$0] }) ?? [] where secret.count >= 4 {
            output = output.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let genericPatterns: [(String, String)] = [
            (#"(?i)((?:proxy-)?authorization\s*[:=]\s*)(?:bearer\s+)?[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)((?:set-)?cookie\s*[:=]\s*)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)([\"']?(?:token|api[-_]?key|client[-_]?secret|user[-_]?password|password|user[-_]?account)[\"']?\s*[:=]\s*[\"']?)[^\"'\s,;}&]+"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:token|user_password|password|user_account)=)[^&#\s]+"#, "$1[REDACTED]"),
            (#"(?i)((?:request[-_]?body|response[-_]?body|portal[-_]?response)\s*[:=]\s*)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[REDACTED]"),
        ]
        for (pattern, replacement) in genericPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if home != "/", !home.isEmpty {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        return String(output.prefix(2_000))
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
                try secureLogFile()
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try secureLogFile()
        } catch {
            // Logging must never prevent the menu-bar app from functioning.
        }
    }

    private func secureLogFile() throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
