import Darwin
import Foundation

final class ExternalFileLockHolder {
    private let process = Process()

    init(lockURL: URL) throws {
        let script = """
        import fcntl, os, sys, time
        path = sys.argv[1]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        handle = open(path, "a+")
        fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("locked", flush=True)
        time.sleep(30)
        """
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lockURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let handshake = output.fileHandleForReading.readData(ofLength: 7)
        guard String(decoding: handshake, as: UTF8.self).contains("locked") else {
            stop()
            throw NSError(
                domain: "SZUNetCoreTests.ExternalFileLockHolder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "测试辅助进程未能持有文件锁。"]
            )
        }
    }

    func stop() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(1)
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return }
            if Date() >= deadline {
                _ = Darwin.kill(pid, SIGKILL)
                while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
                return
            }
            usleep(10_000)
        }
    }

    deinit { stop() }
}
