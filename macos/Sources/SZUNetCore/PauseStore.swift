import Darwin
import Foundation

public final class PauseStore {
    public let fileURL: URL
    public let lockFileURL: URL
    public let legacyFileURL: URL?
    public let migrationFileURL: URL

    private let threadLock = NSLock()
    private let advisoryLock: AdvisoryFileLock
    private let now: () -> Date
    private let bootMarker: () -> String

    public init(
        fileURL: URL = AppPaths.standard.pauseFile,
        lockFileURL: URL? = nil,
        legacyFileURL: URL? = nil,
        migrationFileURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        bootMarker: @escaping () -> String = PauseStore.currentBootMarker
    ) {
        let standardPaths = AppPaths.standard
        let usesStandardLocation = fileURL.standardizedFileURL
            == standardPaths.pauseFile.standardizedFileURL

        self.fileURL = fileURL
        self.lockFileURL = lockFileURL
            ?? (usesStandardLocation
                ? standardPaths.pauseLockFile
                : fileURL.appendingPathExtension("lock"))
        self.legacyFileURL = legacyFileURL
            ?? (usesStandardLocation ? AppPaths.legacyPauseFile : nil)
        self.migrationFileURL = migrationFileURL
            ?? (usesStandardLocation
                ? standardPaths.legacyPauseMigrationFile
                : fileURL.deletingLastPathComponent()
                    .appendingPathComponent(".legacy-pause-migrated-v1"))
        self.now = now
        self.bootMarker = bootMarker
        self.advisoryLock = AdvisoryFileLock(url: self.lockFileURL)
    }

    public func activeState() -> PauseState? {
        threadLock.lock()
        defer { threadLock.unlock() }

        do {
            return try advisoryLock.withExclusiveLock {
                try migrateLegacyPauseIfNeededLocked()
                return activeStateLocked()
            }
        } catch {
            // Failing closed prevents a lock or filesystem problem from silently
            // re-enabling automatic login.
            return PauseState(mode: .manual, pausedAt: now())
        }
    }

    public var isPaused: Bool {
        activeState() != nil
    }

    public func pause(minutes: Int? = nil, untilNextBoot: Bool = false) throws {
        do {
            try withExclusiveAccess {
                let current = now()
                let state: PauseState
                if let minutes {
                    state = PauseState(
                        mode: .until,
                        pausedAt: current,
                        resumeAfter: current.addingTimeInterval(
                            TimeInterval(max(1, minutes)) * 60
                        )
                    )
                } else if untilNextBoot {
                    let marker = bootMarker()
                    guard !marker.isEmpty else {
                        throw SZUNetError.fileSystem("无法读取当前开机标记，未创建暂停状态。")
                    }
                    state = PauseState(
                        mode: .untilNextBoot,
                        pausedAt: current,
                        bootMarker: marker
                    )
                } else {
                    state = PauseState(mode: .manual, pausedAt: current)
                }
                try writeStateLocked(state)
            }
        } catch let error as SZUNetError {
            throw error
        } catch {
            throw SZUNetError.fileSystem("无法写入暂停状态：\(error.localizedDescription)")
        }
    }

    public func resume() throws {
        do {
            try withExclusiveAccess {
                try removePauseFileLocked()
            }
        } catch {
            throw SZUNetError.fileSystem("无法清除暂停状态：\(error.localizedDescription)")
        }
    }

    public func description() -> String {
        guard let state = activeState() else { return "未暂停" }
        switch state.mode {
        case .manual:
            return "已暂停（直到手动恢复）"
        case .until:
            guard let resumeAfter = state.resumeAfter else { return "已暂停（定时恢复）" }
            return "已暂停（预计 \(Self.dateFormatter.string(from: resumeAfter)) 自动恢复）"
        case .untilNextBoot:
            return "已暂停（下次开机恢复）"
        }
    }

    private func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        threadLock.lock()
        defer { threadLock.unlock() }
        return try advisoryLock.withExclusiveLock {
            try migrateLegacyPauseIfNeededLocked()
            return try body()
        }
    }

    private func activeStateLocked() -> PauseState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? SecurePersistence.read(fileURL) else {
            return PauseState(mode: .manual, pausedAt: now())
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PauseState.self, from: data) else {
            return PauseState(mode: .manual, pausedAt: now())
        }

        let expired: Bool
        switch state.mode {
        case .until:
            expired = state.resumeAfter.map { now() >= $0 } ?? false
        case .untilNextBoot:
            let current = bootMarker()
            expired = !(state.bootMarker ?? "").isEmpty
                && !current.isEmpty
                && state.bootMarker != current
        case .manual:
            expired = false
        }
        if expired {
            try? removePauseFileLocked()
            return nil
        }
        return state
    }

    private func migrateLegacyPauseIfNeededLocked() throws {
        guard let legacyFileURL,
              !FileManager.default.fileExists(atPath: migrationFileURL.path),
              FileManager.default.fileExists(atPath: legacyFileURL.path) else {
            return
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: legacyFileURL.path)
            let pausedAt = attributes?[.modificationDate] as? Date ?? now()
            try writeStateLocked(PauseState(mode: .manual, pausedAt: pausedAt))
        }

        try retireLegacyMarkerLocked(at: legacyFileURL)
    }

    private func retireLegacyMarkerLocked(at legacyFileURL: URL) throws {
        do {
            try Self.writeAtomically(
                Data("legacy pause marker migrated\n".utf8),
                to: migrationFileURL
            )
            try? FileManager.default.removeItem(at: legacyFileURL)
        } catch {
            // Removing the source marker is an acceptable one-time record when
            // the destination directory cannot hold the migration sentinel.
            do {
                try FileManager.default.removeItem(at: legacyFileURL)
            } catch let removalError as CocoaError where removalError.code == .fileNoSuchFile {
                return
            } catch {
                throw error
            }
        }
    }

    private func writeStateLocked(_ state: PauseState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(state)
        data.append(0x0A)
        try Self.writeAtomically(data, to: fileURL)
    }

    private func removePauseFileLocked() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        try SecurePersistence.write(data, to: url)
    }

    public static func currentBootMarker() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let status = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &bootTime, &size, nil, 0)
        }
        guard status == 0 else { return "" }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
