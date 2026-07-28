import Foundation

public struct AppPaths: Equatable {
    public var applicationSupportDirectory: URL
    public var logDirectory: URL

    public init(applicationSupportDirectory: URL, logDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.logDirectory = logDirectory
    }

    public static var standard: AppPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppPaths(
            applicationSupportDirectory: home
                .appendingPathComponent("Library/Application Support/szu-netlogin", isDirectory: true),
            logDirectory: home
                .appendingPathComponent("Library/Logs/szu-netlogin", isDirectory: true)
        )
    }

    /// Pause marker used by the retired Python implementation.
    public static var legacyPauseFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".szu-netlogin", isDirectory: true)
            .appendingPathComponent("paused")
    }

    public var configurationFile: URL {
        applicationSupportDirectory.appendingPathComponent("config.json")
    }

    public var campusProviderConfigurationFile: URL {
        applicationSupportDirectory.appendingPathComponent("campus-providers.json")
    }

    public var legacyConfigurationFile: URL {
        applicationSupportDirectory.appendingPathComponent("config.yaml")
    }

    public var pauseFile: URL {
        applicationSupportDirectory.appendingPathComponent("pause.json")
    }

    public var pauseLockFile: URL {
        applicationSupportDirectory.appendingPathComponent("pause.lock")
    }

    public var legacyPauseMigrationFile: URL {
        applicationSupportDirectory.appendingPathComponent(".legacy-pause-migrated-v1")
    }

    public var authenticationLockFile: URL {
        applicationSupportDirectory.appendingPathComponent("authentication.lock")
    }

    public var logFile: URL {
        logDirectory.appendingPathComponent("netlogin.log")
    }

    public var diagnosticDirectory: URL {
        logDirectory.appendingPathComponent("diagnostics", isDirectory: true)
    }

    public func createDirectories() throws {
        do {
            try FileManager.default.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SZUNetError.fileSystem("无法创建应用数据目录：\(error.localizedDescription)")
        }
    }
}
