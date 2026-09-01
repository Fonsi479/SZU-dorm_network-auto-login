import Darwin
import Foundation

public struct ConfigurationLoadResult {
    public var configuration: AppConfiguration
    public var migratedFrom: URL?

    public init(configuration: AppConfiguration, migratedFrom: URL? = nil) {
        self.configuration = configuration
        self.migratedFrom = migratedFrom
    }
}

public final class ConfigurationStore: @unchecked Sendable {
    public let paths: AppPaths
    private let fileManager: FileManager
    private let legacyCandidates: [URL]
    private let lock: AdvisoryFileLock
    private let threadLock = NSLock()

    public init(
        paths: AppPaths = .standard,
        fileManager: FileManager = .default,
        legacyCandidates: [URL]? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.lock = AdvisoryFileLock(url: paths.configurationLockFile)

        if let legacyCandidates {
            self.legacyCandidates = legacyCandidates
        } else {
            var candidates = [paths.legacyConfigurationFile]
            if let configuredHome = ProcessInfo.processInfo.environment["SZU_NETLOGIN_HOME"],
               !configuredHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(
                    URL(fileURLWithPath: configuredHome, isDirectory: true)
                        .appendingPathComponent("config.yaml")
                )
            }
            candidates.append(
                URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("config.yaml")
            )
            self.legacyCandidates = candidates
        }
    }

    public func load() throws -> ConfigurationLoadResult {
        try paths.createDirectories()
        threadLock.lock()
        defer { threadLock.unlock() }
        return try lock.withExclusiveLock { try loadLocked() }
    }

    private func loadLocked() throws -> ConfigurationLoadResult {

        if fileManager.fileExists(atPath: paths.configurationFile.path) {
            do {
                let data = try SecurePersistence.read(paths.configurationFile)
                let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
                return ConfigurationLoadResult(configuration: configuration)
            } catch let error as DecodingError {
                throw SZUNetError.configuration("config.json 格式不正确：\(Self.describe(error))")
            } catch let error as SZUNetError {
                throw error
            } catch {
                throw SZUNetError.configuration("无法读取 config.json：\(error.localizedDescription)")
            }
        }

        for candidate in uniqueLegacyCandidates() where fileManager.fileExists(atPath: candidate.path) {
            do {
                let text = try String(contentsOf: candidate, encoding: .utf8)
                let configuration = try LegacyYAMLConfigurationParser.parse(text)
                try saveLocked(configuration)
                return ConfigurationLoadResult(configuration: configuration, migratedFrom: candidate)
            } catch let error as SZUNetError {
                throw error
            } catch {
                throw SZUNetError.configuration(
                    "无法迁移旧配置 \(candidate.path)：\(error.localizedDescription)"
                )
            }
        }

        let configuration = AppConfiguration.default
        try saveLocked(configuration)
        return ConfigurationLoadResult(configuration: configuration)
    }

    public func save(_ configuration: AppConfiguration) throws {
        try paths.createDirectories()
        threadLock.lock()
        defer { threadLock.unlock() }
        try lock.withExclusiveLock { try saveLocked(configuration) }
    }

    private func saveLocked(_ configuration: AppConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        do {
            var data = try encoder.encode(configuration)
            data.append(0x0A)
            try SecurePersistence.write(data, to: paths.configurationFile)
        } catch let error as SZUNetError {
            throw error
        } catch {
            throw SZUNetError.fileSystem("无法保存配置：\(error.localizedDescription)")
        }
    }

    public func updateUsername(_ username: String) throws -> AppConfiguration {
        try paths.createDirectories()
        threadLock.lock()
        defer { threadLock.unlock() }
        return try lock.withExclusiveLock {
            var result = try loadLocked().configuration
            let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw SZUNetError.configuration("校园网账号不能为空。")
            }
            result.user.username = normalized
            try saveLocked(result)
            return result
        }
    }

    private func uniqueLegacyCandidates() -> [URL] {
        var seen = Set<String>()
        return legacyCandidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return context.debugDescription
        case .keyNotFound(let key, let context):
            return "缺少字段 \(key.stringValue)：\(context.debugDescription)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }
}
