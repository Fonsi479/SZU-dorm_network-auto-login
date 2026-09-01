import Darwin
import Foundation

enum SecurePersistence {
    static func prepareDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw error("安全数据目录不是普通目录", path: path)
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard chmod(path, S_IRWXU) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EPERM)
        }
    }

    static func read(_ url: URL) throws -> Data {
        try rejectSymbolicLink(at: url)
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        try rejectSymbolicLink(at: url, allowMissing: true)
        try data.write(to: url, options: .atomic)
        try rejectSymbolicLink(at: url)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EPERM)
        }
    }

    static func rejectSymbolicLink(at url: URL, allowMissing: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw error("拒绝访问符号链接", path: url.path)
            }
        } else if !(allowMissing && errno == ENOENT) {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func error(_ message: String, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ELOOP),
            userInfo: [NSLocalizedDescriptionKey: "\(message)：\(path)", NSFilePathErrorKey: path]
        )
    }
}
