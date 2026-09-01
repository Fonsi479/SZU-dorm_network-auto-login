import Darwin
import Foundation

struct AdvisoryFileLock {
    let url: URL

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try SecurePersistence.prepareDirectory(url.deletingLastPathComponent())
        try SecurePersistence.rejectSymbolicLink(at: url, allowMissing: true)

        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open", path: url.path)
        }
        defer { _ = Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        var writeLock = Self.lockDescription(type: F_WRLCK)
        while Darwin.fcntl(descriptor, F_SETLKW, &writeLock) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw Self.posixError(operation: "fcntl lock", path: url.path, code: code)
        }
        defer {
            var unlock = Self.lockDescription(type: F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        }

        return try body()
    }

    private static func lockDescription(type: Int32) -> Darwin.flock {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        return lock
    }

    private static func posixError(
        operation: String,
        path: String,
        code: Int32 = errno
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) \(path): \(String(cString: strerror(code)))",
                NSFilePathErrorKey: path,
            ]
        )
    }
}
