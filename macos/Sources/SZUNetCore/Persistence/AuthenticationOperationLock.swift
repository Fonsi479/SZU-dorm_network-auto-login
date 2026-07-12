import Darwin
import Foundation

struct AuthenticationOperationLock {
    let url: URL

    init(url: URL = AppPaths.standard.authenticationLockFile) {
        self.url = url
    }

    func tryAcquire() throws -> AuthenticationOperationLease? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw posixError("open") }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        var lock = lockDescription(type: F_WRLCK)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EACCES || code == EAGAIN { return nil }
            throw posixError("fcntl lock", code: code)
        }
        return AuthenticationOperationLease(descriptor: descriptor)
    }

    private func lockDescription(type: Int32) -> Darwin.flock {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        return lock
    }

    private func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) \(url.path): \(String(cString: strerror(code)))",
                NSFilePathErrorKey: url.path,
            ]
        )
    }
}
final class AuthenticationOperationLease {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    func release() {
        guard descriptor >= 0 else { return }
        var unlock = Darwin.flock()
        unlock.l_start = 0
        unlock.l_len = 0
        unlock.l_pid = 0
        unlock.l_type = Int16(F_UNLCK)
        unlock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}
