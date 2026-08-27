import Foundation

public struct CampusProviderProductStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var accountLabel: String
    public var lifecycle: String
    public var errorCode: String?

    public init(enabled: Bool, accountLabel: String, lifecycle: String = "idle", errorCode: String? = nil) {
        self.enabled = enabled
        self.accountLabel = accountLabel
        self.lifecycle = lifecycle
        self.errorCode = errorCode
    }
}

public struct CampusProductSnapshot: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var category: CampusNetworkCategory
    public var automaticEnabled: Bool
    public var dorm: CampusProviderProductStatus
    public var teaching: CampusProviderProductStatus
    public var lastErrorCode: String?

    public init(
        generation: UInt64,
        category: CampusNetworkCategory,
        automaticEnabled: Bool,
        dorm: CampusProviderProductStatus,
        teaching: CampusProviderProductStatus,
        lastErrorCode: String? = nil
    ) {
        self.generation = generation
        self.category = category
        self.automaticEnabled = automaticEnabled
        self.dorm = dorm
        self.teaching = teaching
        self.lastErrorCode = lastErrorCode
    }
}

public actor CampusProductController {
    private let detector: CampusEnvironmentDetecting
    private let coordinator: CampusNetworkCoordinator
    private let settingsStore: CampusProviderSettingsStore
    private let pauseStore: PauseStore
    private var configuration: CampusProductConfiguration
    private var generation: UInt64
    private var latestDetection: CampusDetection?
    private var latestStatus: CampusCoordinatorStatus?
    private var lastResult: ProviderAuthResult?

    public init(
        detector: CampusEnvironmentDetecting,
        coordinator: CampusNetworkCoordinator,
        settingsStore: CampusProviderSettingsStore,
        pauseStore: PauseStore,
        configuration: CampusProductConfiguration,
        generation: UInt64 = 0
    ) {
        self.detector = detector
        self.coordinator = coordinator
        self.settingsStore = settingsStore
        self.pauseStore = pauseStore
        self.configuration = configuration
        self.generation = generation
    }

    public func currentSnapshot() -> CampusProductSnapshot {
        snapshot()
    }

    @discardableResult
    public func refresh() async -> CampusProductSnapshot {
        let detection = await detector.detect(
            generation: generation,
            configuration: configuration
        )
        latestDetection = detection
        latestStatus = await coordinator.status(
            context: detection.context,
            usernames: [
                .dorm: configuration.dorm.accountLabel,
                .teaching: configuration.teaching.accountLabel,
            ]
        )
        return snapshot()
    }

    public func login(
        requestedProvider: CampusProviderID? = nil,
        automatic: Bool = false
    ) async -> ProviderAuthResult {
        if automatic, pauseStore.isPaused {
            return .blocked(.dorm, "PROVIDER_DISABLED")
        }
        let detection = await detector.detect(
            generation: generation,
            configuration: configuration
        )
        latestDetection = detection
        guard detection.category == .dorm || detection.category == .teaching else {
            let code = detection.category == .ambiguous ? "ENV_AMBIGUOUS" : "ENV_NON_CAMPUS"
            let result = ProviderAuthResult.blocked(.dorm, code)
            lastResult = result
            return result
        }
        let providerID: CampusProviderID = detection.category == .dorm ? .dorm : .teaching
        if let requestedProvider, requestedProvider != providerID {
            let result = ProviderAuthResult.blocked(requestedProvider, "ENV_AMBIGUOUS")
            lastResult = result
            return result
        }
        let account = configuration.settings(for: providerID).accountLabel
        guard !account.isEmpty else {
            let result = ProviderAuthResult.blocked(providerID, "CFG_INVALID")
            lastResult = result
            return result
        }
        let result = await coordinator.login(
            context: detection.context,
            username: account,
            requestedProvider: requestedProvider ?? providerID,
            automatic: automatic
        )
        lastResult = result
        if result.sessionState != .unknown {
            latestStatus = CampusCoordinatorStatus(
                providerID: result.providerID,
                session: ProviderSessionResult(
                    state: result.sessionState,
                    accountMatch: result.accountMatch,
                    clientIP: result.clientIP,
                    errorCode: result.errorCode,
                    retryable: result.retryable
                ),
                errorCode: result.errorCode
            )
        }
        return result
    }

    public func logout(providerID: CampusProviderID) async -> ProviderAuthResult {
        let detection: CampusDetection
        if let latestDetection {
            detection = latestDetection
        } else {
            detection = await detector.detect(
                generation: generation,
                configuration: configuration
            )
        }
        latestDetection = detection
        let account = configuration.settings(for: providerID).accountLabel
        let result = await coordinator.logout(
            context: detection.context,
            username: account,
            providerID: providerID
        )
        lastResult = result
        return result
    }

    public func networkChanged() async {
        generation &+= 1
        latestDetection = nil
        latestStatus = nil
        await coordinator.networkChanged(to: generation)
    }

    public func updateConfiguration(_ configuration: CampusProductConfiguration) async throws {
        try settingsStore.save(configuration)
        self.configuration = configuration
        await coordinator.updateSettings(configuration.coordinatorSettings)
        latestDetection = nil
        latestStatus = nil
    }

    public func pause() throws {
        try pauseStore.pause()
    }

    public func resume() async throws {
        if !configuration.automaticEnabled {
            var updated = configuration
            updated.automaticEnabled = true
            try settingsStore.save(updated)
            configuration = updated
            await coordinator.updateSettings(updated.coordinatorSettings)
        }
        try pauseStore.resume()
    }

    private func snapshot() -> CampusProductSnapshot {
        let category = latestDetection?.category ?? .unknown
        let selectedProvider = latestStatus?.providerID
        let selectedLifecycle = latestStatus?.session?.state.rawValue ?? "idle"
        return CampusProductSnapshot(
            generation: generation,
            category: category,
            automaticEnabled: configuration.automaticEnabled && !pauseStore.isPaused,
            dorm: CampusProviderProductStatus(
                enabled: configuration.dorm.enabled,
                accountLabel: Self.maskedAccount(configuration.dorm.accountLabel),
                lifecycle: selectedProvider == .dorm ? selectedLifecycle : "idle",
                errorCode: selectedProvider == .dorm
                    ? latestStatus?.errorCode
                    : (lastResult?.providerID == .dorm ? lastResult?.errorCode : nil)
            ),
            teaching: CampusProviderProductStatus(
                enabled: configuration.teaching.enabled,
                accountLabel: Self.maskedAccount(configuration.teaching.accountLabel),
                lifecycle: selectedProvider == .teaching ? selectedLifecycle : "idle",
                errorCode: selectedProvider == .teaching
                    ? latestStatus?.errorCode
                    : (lastResult?.providerID == .teaching ? lastResult?.errorCode : nil)
            ),
            lastErrorCode: latestDetection?.errorCode
                ?? latestStatus?.errorCode
                ?? lastResult?.errorCode
        )
    }

    private static func maskedAccount(_ account: String) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let local = String(parts[0])
        let masked: String
        if local.count < 3 {
            masked = "****"
        } else {
            masked = "\(local.first!)***\(local.last!)"
        }
        return parts.count == 2 ? masked + "@" + String(parts[1]) : masked
    }
}

public enum CampusProductRuntime {
    public static func make(paths: AppPaths = .standard) throws -> CampusProductController {
        let configurationStore = ConfigurationStore(paths: paths)
        let legacy = try configurationStore.load().configuration
        let settingsStore = CampusProviderSettingsStore(fileURL: paths.campusProviderConfigurationFile)
        let settings = try settingsStore.load(legacyConfiguration: legacy)
        let broker = CampusKeychainCredentialBroker(settingsStore: settingsStore)
        let dorm = DormDrCOMProvider(client: DrCOMClient(configuration: legacy))
        let teaching = TeachingSRunProvider(transport: SRunHTTPTransport())
        let coordinator = CampusNetworkCoordinator(
            providers: [dorm, teaching],
            credentialBroker: broker,
            settings: settings.coordinatorSettings,
            authenticationLockURL: paths.authenticationLockFile
        )
        let detector = CampusEnvironmentDetector(
            legacyConfiguration: legacy
        )
        return CampusProductController(
            detector: detector,
            coordinator: coordinator,
            settingsStore: settingsStore,
            pauseStore: PauseStore(
                fileURL: paths.pauseFile,
                lockFileURL: paths.pauseLockFile,
                legacyFileURL: AppPaths.legacyPauseFile,
                migrationFileURL: paths.legacyPauseMigrationFile
            ),
            configuration: settings
        )
    }
}
