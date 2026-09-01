import Foundation

public struct CampusAutomationHost: Codable, Equatable, Sendable {
    public var hostID: String
    public var displayName: String
    public var bundleID: String
    public var supportsOwnershipProtocol: Bool

    public init(
        hostID: String,
        displayName: String,
        bundleID: String,
        supportsOwnershipProtocol: Bool = true
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.bundleID = bundleID
        self.supportsOwnershipProtocol = supportsOwnershipProtocol
    }
}

public struct CampusAutomationOwner: Codable, Equatable, Sendable {
    public var host: CampusAutomationHost
    public var running: Bool
    public var updatedAt: Date

    public init(host: CampusAutomationHost, running: Bool, updatedAt: Date = Date()) {
        self.host = host
        self.running = running
        self.updatedAt = updatedAt
    }
}

public struct CampusAutomationConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var networkProbeEnabled: Bool
    public var probeIntervalSeconds: Int
    public var owner: CampusAutomationOwner?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        networkProbeEnabled: Bool = true,
        probeIntervalSeconds: Int = CampusAutomationPreferences.defaultProbeIntervalSeconds,
        owner: CampusAutomationOwner? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.networkProbeEnabled = networkProbeEnabled
        self.probeIntervalSeconds = CampusAutomationPreferences.normalizedProbeInterval(probeIntervalSeconds)
        self.owner = owner
    }
}

public struct CampusAutomationOwnershipSnapshot: Equatable, Sendable {
    public var currentOwner: CampusAutomationHost?
    public var ownerRunning: Bool
    public var canTransfer: Bool
    public var isCurrentHostOwner: Bool

    public init(
        currentOwner: CampusAutomationHost?,
        ownerRunning: Bool,
        canTransfer: Bool,
        isCurrentHostOwner: Bool
    ) {
        self.currentOwner = currentOwner
        self.ownerRunning = ownerRunning
        self.canTransfer = canTransfer
        self.isCurrentHostOwner = isCurrentHostOwner
    }
}

public enum CampusAutomationOwnershipError: Error, Equatable, Sendable {
    case ownedByAnotherHost(String)
    case legacyOwnerRequiresUpgrade(String)
    case callerIsNotOwner
}

public final class CampusAutomationStore: @unchecked Sendable {
    public let fileURL: URL
    public let lockFileURL: URL

    private let threadLock = NSLock()
    private let advisoryLock: AdvisoryFileLock
    private let legacyOwner: CampusAutomationHost?
    private let now: () -> Date

    public init(
        fileURL: URL = AppPaths.standard.automationFile,
        lockFileURL: URL? = nil,
        legacyOwner: CampusAutomationHost? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        let standardPaths = AppPaths.standard
        self.lockFileURL = lockFileURL ?? (
            fileURL.standardizedFileURL == standardPaths.automationFile.standardizedFileURL
                ? standardPaths.automationLockFile
                : fileURL.appendingPathExtension("lock")
        )
        self.advisoryLock = AdvisoryFileLock(url: self.lockFileURL)
        self.legacyOwner = legacyOwner
        self.now = now
    }

    public func load() throws -> CampusAutomationConfiguration {
        try withLock { try loadLocked() }
    }

    public func updateProbe(enabled: Bool, intervalSeconds: Int) throws -> CampusAutomationConfiguration {
        try withLock {
            var configuration = try loadLocked()
            configuration.networkProbeEnabled = enabled
            configuration.probeIntervalSeconds = CampusAutomationPreferences.normalizedProbeInterval(intervalSeconds)
            try saveLocked(configuration)
            return configuration
        }
    }

    public func claimOwnership(for host: CampusAutomationHost, running: Bool = true) throws -> CampusAutomationOwnershipSnapshot {
        try withLock {
            var configuration = try loadLocked()
            if let owner = configuration.owner, owner.host.hostID != host.hostID {
                if !owner.host.supportsOwnershipProtocol {
                    throw CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(owner.host.displayName)
                }
                throw CampusAutomationOwnershipError.ownedByAnotherHost(owner.host.displayName)
            }
            configuration.owner = CampusAutomationOwner(host: host, running: running, updatedAt: now())
            try saveLocked(configuration)
            return Self.snapshot(configuration, for: host.hostID)
        }
    }

    public func transferOwnership(to host: CampusAutomationHost, running: Bool = true) throws -> CampusAutomationOwnershipSnapshot {
        try withLock {
            var configuration = try loadLocked()
            if let owner = configuration.owner,
               owner.host.hostID != host.hostID,
               !owner.host.supportsOwnershipProtocol {
                throw CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(owner.host.displayName)
            }
            configuration.owner = CampusAutomationOwner(host: host, running: running, updatedAt: now())
            try saveLocked(configuration)
            return Self.snapshot(configuration, for: host.hostID)
        }
    }

    public func setOwnerRunning(_ running: Bool, hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try withLock {
            var configuration = try loadLocked()
            guard configuration.owner?.host.hostID == hostID else {
                throw CampusAutomationOwnershipError.callerIsNotOwner
            }
            configuration.owner?.running = running
            configuration.owner?.updatedAt = now()
            try saveLocked(configuration)
            return Self.snapshot(configuration, for: hostID)
        }
    }

    public func refreshOwnerCapability(
        hostID: String,
        supportsOwnershipProtocol: Bool
    ) throws -> CampusAutomationOwnershipSnapshot {
        try withLock {
            var configuration = try loadLocked()
            guard configuration.owner?.host.hostID == hostID else {
                throw CampusAutomationOwnershipError.callerIsNotOwner
            }
            configuration.owner?.host.supportsOwnershipProtocol = supportsOwnershipProtocol
            configuration.owner?.updatedAt = now()
            try saveLocked(configuration)
            return Self.snapshot(configuration, for: hostID)
        }
    }

    public func releaseOwnership(hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try withLock {
            var configuration = try loadLocked()
            guard configuration.owner?.host.hostID == hostID else {
                throw CampusAutomationOwnershipError.callerIsNotOwner
            }
            configuration.owner = nil
            try saveLocked(configuration)
            return Self.snapshot(configuration, for: hostID)
        }
    }

    /// Must be called immediately before automatic credential access.
    public func verifyOwnership(hostID: String) throws -> Bool {
        try withLock { try loadLocked().owner?.host.hostID == hostID }
    }

    public func ownershipSnapshot(for hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try withLock { Self.snapshot(try loadLocked(), for: hostID) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        threadLock.lock()
        defer { threadLock.unlock() }
        return try advisoryLock.withExclusiveLock { try body() }
    }

    private func loadLocked() throws -> CampusAutomationConfiguration {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let configuration = try decoder.decode(
                CampusAutomationConfiguration.self,
                from: SecurePersistence.read(fileURL)
            )
            guard configuration.schemaVersion == CampusAutomationConfiguration.currentSchemaVersion else {
                throw SZUNetError.configuration("不支持的 automation.json 版本。")
            }
            return configuration
        }
        let owner = legacyOwner.map {
            CampusAutomationOwner(
                host: CampusAutomationHost(
                    hostID: $0.hostID,
                    displayName: $0.displayName,
                    bundleID: $0.bundleID,
                    supportsOwnershipProtocol: false
                ),
                running: true,
                updatedAt: now()
            )
        }
        let configuration = CampusAutomationConfiguration(owner: owner)
        try saveLocked(configuration)
        return configuration
    }

    private func saveLocked(_ configuration: CampusAutomationConfiguration) throws {
        var data = try JSONEncoder.securePersistence.encode(configuration)
        data.append(0x0A)
        try SecurePersistence.write(data, to: fileURL)
    }

    private static func snapshot(
        _ configuration: CampusAutomationConfiguration,
        for hostID: String
    ) -> CampusAutomationOwnershipSnapshot {
        let owner = configuration.owner
        let sameHost = owner?.host.hostID == hostID
        return CampusAutomationOwnershipSnapshot(
            currentOwner: owner?.host,
            ownerRunning: owner?.running ?? false,
            canTransfer: owner == nil || sameHost || owner?.host.supportsOwnershipProtocol == true,
            isCurrentHostOwner: sameHost
        )
    }
}

private extension JSONEncoder {
    static var securePersistence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
