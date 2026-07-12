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
            process.terminate()
            process.waitUntilExit()
            throw NSError(
                domain: "SZUNetCoreTests.ExternalFileLockHolder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "测试辅助进程未能持有文件锁。"]
            )
        }
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit { stop() }
}
