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
    private let fileManager: FileManager

    public init(
        fileURL: URL = AppPaths.standard.campusProviderConfigurationFile,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load(legacyConfiguration: AppConfiguration? = nil) throws -> CampusProductConfiguration {
        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(CampusProductConfiguration.self, from: data)
            guard decoded.schemaVersion == CampusProductConfiguration.currentSchemaVersion else {
                throw SZUNetError.configuration("不支持的校园网 Provider 配置版本。")
            }
            return decoded
        }
        let configuration = legacyConfiguration.map(CampusProductConfiguration.migrating) ?? .default
        try save(configuration)
        return configuration
    }

    public func save(_ configuration: CampusProductConfiguration) throws {
        guard configuration.schemaVersion == CampusProductConfiguration.currentSchemaVersion else {
            throw SZUNetError.configuration("校园网 Provider 配置必须使用 schema v2。")
        }
        try Self.validate(configuration)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

    public init(
        settingsStore: CampusProviderSettingsStore,
        credentialStore: CredentialStoring = KeychainStore()
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
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
        guard let password = try credentialStore.password(
            service: service,
            account: provider.credentialReference
        ), !password.isEmpty else { return nil }
        return CredentialHandle(password)
    }
}
