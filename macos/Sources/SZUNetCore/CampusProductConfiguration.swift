import Foundation

public struct CampusProviderSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var accountLabel: String
    public var credentialReference: String

    public init(enabled: Bool, accountLabel: String = "", credentialReference: String = "") {
        self.enabled = enabled
        self.accountLabel = accountLabel
        self.credentialReference = credentialReference
    }
}

public struct CampusProductConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var automaticEnabled: Bool
    public var dorm: CampusProviderSettings
    public var teaching: CampusProviderSettings
    public var teachingPortalURL: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        automaticEnabled: Bool = true,
        dorm: CampusProviderSettings = .init(enabled: true, credentialReference: "dorm-default"),
        teaching: CampusProviderSettings = .init(enabled: false, credentialReference: "teaching-default"),
        teachingPortalURL: String = "https://net.szu.edu.cn/srun_portal_pc"
    ) {
        self.schemaVersion = schemaVersion
        self.automaticEnabled = automaticEnabled
        self.dorm = dorm
        self.teaching = teaching
        self.teachingPortalURL = teachingPortalURL
    }

    public static let `default` = CampusProductConfiguration()

    public static func migrating(_ legacy: AppConfiguration) -> CampusProductConfiguration {
        let username = legacy.user.username == UserConfiguration.placeholder ? "" : legacy.user.username
        return CampusProductConfiguration(
            dorm: CampusProviderSettings(
                enabled: true,
                accountLabel: username,
                credentialReference: legacy.keychainAccount.isEmpty ? "dorm-default" : legacy.keychainAccount
            ),
            teaching: CampusProviderSettings(enabled: false, credentialReference: "teaching-default")
        )
    }

    public var coordinatorSettings: CampusCoordinatorSettings {
        CampusCoordinatorSettings(
            dormEnabled: dorm.enabled,
            teachingEnabled: teaching.enabled,
            automaticEnabled: automaticEnabled
        )
    }

    public func settings(for providerID: CampusProviderID) -> CampusProviderSettings {
        providerID == .dorm ? dorm : teaching
    }
}

public final class CampusProviderSettingsStore: @unchecked Sendable {
    public let fileURL: URL
    public let lockFileURL: URL
    private let fileManager: FileManager
    private let threadLock = NSLock()
    private let advisoryLock: AdvisoryFileLock

    public init(
        fileURL: URL = AppPaths.standard.campusProviderConfigurationFile,
        lockFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        let standardPaths = AppPaths.standard
        self.lockFileURL = lockFileURL ?? (
            fileURL.standardizedFileURL == standardPaths.campusProviderConfigurationFile.standardizedFileURL
                ? standardPaths.campusProviderConfigurationLockFile
                : fileURL.appendingPathExtension("lock")
        )
        self.fileManager = fileManager
        self.advisoryLock = AdvisoryFileLock(url: self.lockFileURL)
    }

    public func load(legacyConfiguration: AppConfiguration? = nil) throws -> CampusProductConfiguration {
        threadLock.lock()
        defer { threadLock.unlock() }
        return try advisoryLock.withExclusiveLock {
            try loadLocked(legacyConfiguration: legacyConfiguration)
        }
    }

    private func loadLocked(legacyConfiguration: AppConfiguration?) throws -> CampusProductConfiguration {
        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try SecurePersistence.read(fileURL)
            let decoded = try JSONDecoder().decode(CampusProductConfiguration.self, from: data)
            guard decoded.schemaVersion == CampusProductConfiguration.currentSchemaVersion else {
                throw SZUNetError.configuration("不支持的校园网 Provider 配置版本。")
            }
            return decoded
        }
        let configuration = legacyConfiguration.map(CampusProductConfiguration.migrating) ?? .default
        try saveLocked(configuration)
        return configuration
    }

    public func save(_ configuration: CampusProductConfiguration) throws {
        threadLock.lock()
        defer { threadLock.unlock() }
        try advisoryLock.withExclusiveLock { try saveLocked(configuration) }
    }

    private func saveLocked(_ configuration: CampusProductConfiguration) throws {
        guard configuration.schemaVersion == CampusProductConfiguration.currentSchemaVersion else {
            throw SZUNetError.configuration("校园网 Provider 配置必须使用 schema v2。")
        }
        try Self.validate(configuration)
        try SecurePersistence.prepareDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try SecurePersistence.write(data, to: fileURL)
    }

    private static func validate(_ configuration: CampusProductConfiguration) throws {
        for (name, provider) in [("Dorm", configuration.dorm), ("Teaching", configuration.teaching)] {
            guard provider.accountLabel.count <= 128 else {
                throw SZUNetError.configuration("\(name) 账号标签过长。")
            }
            let range = NSRange(
                provider.credentialReference.startIndex..<provider.credentialReference.endIndex,
                in: provider.credentialReference
            )
            let expression = try NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,160}$")
            guard expression.firstMatch(
                in: provider.credentialReference,
                range: range
            ) != nil else {
                throw SZUNetError.configuration("\(name) credential reference 格式无效。")
            }
        }
        guard let portal = URL(string: configuration.teachingPortalURL),
              portal.scheme?.lowercased() == "https",
              portal.host?.lowercased() == "net.szu.edu.cn" else {
            throw SZUNetError.configuration("Teaching 入口必须使用 net.szu.edu.cn 的 HTTPS 地址。")
        }
    }
}

public actor CampusKeychainCredentialBroker: CampusCredentialBroker {
    private let settingsStore: CampusProviderSettingsStore
    private let credentialStore: CredentialStoring
    private let accessMode: CampusCredentialAccessMode

    public init(
        settingsStore: CampusProviderSettingsStore,
        credentialStore: CredentialStoring = KeychainStore(),
        accessMode: CampusCredentialAccessMode = .local
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.accessMode = accessMode
    }

    public nonisolated static func serviceName(for providerID: CampusProviderID) -> String {
        providerID == .dorm
            ? "szu-netlogin"
            : "cn.edu.szu.campus-network.teaching"
    }

    public func openCredential(for providerID: CampusProviderID, username: String) async throws -> CredentialHandle? {
        let configuration = try settingsStore.load()
        let provider = configuration.settings(for: providerID)
        guard provider.enabled, !provider.credentialReference.isEmpty else { return nil }
        let service = Self.serviceName(for: providerID)
        let password: String?
        switch accessMode {
        case .local:
            password = try credentialStore.password(service: service, account: provider.credentialReference)
        case .shared(let accessGroup, let legacyLocations):
            guard let groupedStore = credentialStore as? any AccessGroupCredentialStoring else {
                throw SZUNetError.credential("当前凭据存储不支持共享 access group。")
            }
            if let shared = try groupedStore.password(
                service: service,
                account: provider.credentialReference,
                accessGroup: accessGroup
            ), !shared.isEmpty {
                password = shared
            } else {
                var migrated: String?
                for location in legacyLocations
                where migrated == nil
                    && (location.provider == nil || location.provider == providerID) {
                    migrated = try groupedStore.password(
                        service: location.service ?? service,
                        account: provider.credentialReference,
                        accessGroup: location.accessGroup
                    )
                }
                if let migrated, !migrated.isEmpty {
                    try groupedStore.setPassword(
                        migrated,
                        service: service,
                        account: provider.credentialReference,
                        accessGroup: accessGroup
                    )
                }
                password = migrated
            }
        }
        guard let password, !password.isEmpty else { return nil }
        return CredentialHandle(password)
    }
}
