import Foundation
import SZUNETFeature
import SZUNetCore

public protocol SZUNETEmbeddedControlling: Sendable {
    func currentSnapshot() async -> CampusProductSnapshot
    func refresh() async -> CampusProductSnapshot
    func login(requestedProvider: CampusProviderID?, automatic: Bool) async -> ProviderAuthResult
    func recoverAutomatically() async -> ProviderAuthResult
    func forceLogin(requestedProvider: CampusProviderID?) async -> ProviderAuthResult
    func logout(providerID: CampusProviderID) async -> ProviderAuthResult
    func pause() async throws
    func resume() async throws
    func networkChanged() async
    func updateConfiguration(_ configuration: CampusProductConfiguration) async throws
}

extension CampusProductController: SZUNETEmbeddedControlling {}

public extension SZUNETEmbeddedControlling {
    func recoverAutomatically() async -> ProviderAuthResult {
        await login(requestedProvider: nil, automatic: true)
    }
}

public protocol SZUNETEmbeddedStateStoring: Sendable {
    func loadProviderConfiguration() async throws -> CampusProductConfiguration
    func savePassword(_ password: String, provider: CampusProviderID) async throws
    func automationConfiguration() async throws -> CampusAutomationConfiguration
    func ownership(for hostID: String) async throws -> CampusAutomationOwnershipSnapshot
    func claimOwnership(for host: CampusAutomationHost) async throws -> CampusAutomationOwnershipSnapshot
    func transferOwnership(to host: CampusAutomationHost) async throws -> CampusAutomationOwnershipSnapshot
    func releaseOwnership(from hostID: String) async throws -> CampusAutomationOwnershipSnapshot
    func setOwnerRunning(_ running: Bool, hostID: String) async throws -> CampusAutomationOwnershipSnapshot
    func refreshOwnerCapability(hostID: String, supportsOwnershipProtocol: Bool) async throws -> CampusAutomationOwnershipSnapshot
    func verifyOwnership(hostID: String) async throws -> Bool
    func setProbeEnabled(_ enabled: Bool) async throws
    func setProbeInterval(_ seconds: Int) async throws
}

public protocol SZUNETHostCapabilityChecking: Sendable {
    func supportsOwnershipProtocol(bundleIdentifier: String) async -> Bool
}

public actor SZUNETCoreStateStore: SZUNETEmbeddedStateStoring {
    private let settingsStore: CampusProviderSettingsStore
    private let credentialStore: any CredentialStoring
    private let credentialMode: CampusCredentialAccessMode
    private let automationStore: CampusAutomationStore

    public init(
        paths: AppPaths,
        credentialStore: any CredentialStoring = KeychainStore(),
        credentialMode: CampusCredentialAccessMode = .local,
        legacyOwner: CampusAutomationHost? = nil
    ) {
        settingsStore = CampusProviderSettingsStore(fileURL: paths.campusProviderConfigurationFile)
        self.credentialStore = credentialStore
        self.credentialMode = credentialMode
        automationStore = CampusAutomationStore(
            fileURL: paths.automationFile,
            lockFileURL: paths.automationLockFile,
            legacyOwner: legacyOwner
        )
    }

    public func loadProviderConfiguration() throws -> CampusProductConfiguration {
        try settingsStore.load()
    }

    public func savePassword(_ password: String, provider: CampusProviderID) throws {
        let configuration = try settingsStore.load()
        let reference = configuration.settings(for: provider).credentialReference
        let service = CampusKeychainCredentialBroker.serviceName(for: provider)
        switch credentialMode {
        case .local:
            try credentialStore.setPassword(password, service: service, account: reference)
        case .shared(let accessGroup, _):
            guard let grouped = credentialStore as? any AccessGroupCredentialStoring else {
                throw SZUNetError.credential("当前凭据存储不支持共享 access group。")
            }
            try grouped.setPassword(password, service: service, account: reference, accessGroup: accessGroup)
        }
    }

    public func automationConfiguration() throws -> CampusAutomationConfiguration { try automationStore.load() }
    public func ownership(for hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.ownershipSnapshot(for: hostID)
    }
    public func claimOwnership(for host: CampusAutomationHost) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.claimOwnership(for: host)
    }

    public func transferOwnership(to host: CampusAutomationHost) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.transferOwnership(to: host)
    }

    public func releaseOwnership(from hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.releaseOwnership(hostID: hostID)
    }

    public func setOwnerRunning(_ running: Bool, hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.setOwnerRunning(running, hostID: hostID)
    }

    public func refreshOwnerCapability(
        hostID: String,
        supportsOwnershipProtocol: Bool
    ) throws -> CampusAutomationOwnershipSnapshot {
        try automationStore.refreshOwnerCapability(
            hostID: hostID,
            supportsOwnershipProtocol: supportsOwnershipProtocol
        )
    }

    public func verifyOwnership(hostID: String) throws -> Bool {
        try automationStore.verifyOwnership(hostID: hostID)
    }

    public func setProbeEnabled(_ enabled: Bool) throws {
        let current = try automationStore.load()
        _ = try automationStore.updateProbe(enabled: enabled, intervalSeconds: current.probeIntervalSeconds)
    }

    public func setProbeInterval(_ seconds: Int) throws {
        let current = try automationStore.load()
        _ = try automationStore.updateProbe(enabled: current.networkProbeEnabled, intervalSeconds: seconds)
    }
}

public enum SZUNETEmbeddedError: Error, Equatable, Sendable {
    case invalidProviderConfiguration
    case ownershipTransferBlocked(String)
}

public actor SZUNETEmbeddedRuntime: SZUNETCommandExecuting {
    public let configuration: SZUNETEmbeddedConfiguration
    private let controller: any SZUNETEmbeddedControlling
    private let stateStore: any SZUNETEmbeddedStateStoring
    private let capabilityChecker: any SZUNETHostCapabilityChecking
    private let logger: AppLogger
    private let requestID: @Sendable () -> String
    private var enabled = false
    private var fallbackTask: Task<Void, Never>?
    private var recoveryInProgress = false

    public init(
        configuration: SZUNETEmbeddedConfiguration,
        controller: any SZUNETEmbeddedControlling,
        stateStore: any SZUNETEmbeddedStateStoring,
        capabilityChecker: any SZUNETHostCapabilityChecking = SZUNETMacHostCapabilityChecker(),
        logger: AppLogger = AppLogger(),
        requestID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.configuration = configuration
        self.controller = controller
        self.stateStore = stateStore
        self.capabilityChecker = capabilityChecker
        self.logger = logger
        self.requestID = requestID
    }

    public static func make(configuration: SZUNETEmbeddedConfiguration) throws -> SZUNETEmbeddedRuntime {
        let paths = AppPaths(
            applicationSupportDirectory: configuration.sharedDirectory,
            logDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/szu-netlogin", isDirectory: true)
        )
        let legacyOwner = legacyOwnerIfNeeded(paths: paths)
        let stateStore = SZUNETCoreStateStore(
            paths: paths,
            credentialMode: configuration.credentialMode,
            legacyOwner: legacyOwner
        )
        return SZUNETEmbeddedRuntime(
            configuration: configuration,
            controller: try CampusProductRuntime.make(
                paths: paths,
                credentialAccessMode: configuration.credentialMode,
                automaticCredentialAuthorization: {
                    (try? await stateStore.verifyOwnership(hostID: configuration.hostID)) == true
                }
            ),
            stateStore: stateStore,
            logger: AppLogger(fileURL: paths.logFile)
        )
    }

    static func legacyOwnerIfNeeded(
        paths: AppPaths,
        fileManager: FileManager = .default
    ) -> CampusAutomationHost? {
        guard !fileManager.fileExists(atPath: paths.automationFile.path) else { return nil }
        let hasExistingConfiguration = fileManager.fileExists(
            atPath: paths.campusProviderConfigurationFile.path
        ) || fileManager.fileExists(atPath: paths.configurationFile.path)
        guard hasExistingConfiguration else { return nil }
        return CampusAutomationHost(
            hostID: "com.szu-netlogin.dorm-login",
            displayName: "SZU Dorm Login",
            bundleID: "com.szu-netlogin.dorm-login",
            supportsOwnershipProtocol: false
        )
    }

    public func start(enabled shouldEnable: Bool) async throws {
        guard shouldEnable else { enabled = false; fallbackTask?.cancel(); fallbackTask = nil; return }
        guard !enabled else { return }
        enabled = true
        let ownership = try await stateStore.ownership(for: configuration.hostID)
        if ownership.currentOwner == nil {
            _ = try await stateStore.claimOwnership(for: host)
        } else if ownership.isCurrentHostOwner {
            _ = try await stateStore.setOwnerRunning(true, hostID: configuration.hostID)
        }
        scheduleFallback()
    }

    public func setEnabled(_ value: Bool) async throws {
        try await start(enabled: value)
    }

    /// Returns the current Core product snapshot without exposing the Core
    /// controller to host shells. The menu-bar shell uses this for its own
    /// scheduler lane while the embedded management view may use execute().
    public func currentProductSnapshot() async -> CampusProductSnapshot {
        await controller.currentSnapshot()
    }

    /// Performs one status refresh through the shared in-process controller.
    public func refreshProduct() async -> CampusProductSnapshot {
        await controller.refresh()
    }

    /// Executes a manual or (when explicitly requested by a host scheduler)
    /// Provider login through Core.
    public func login(
        requestedProvider: CampusProviderID? = nil,
        automatic: Bool = false
    ) async -> ProviderAuthResult {
        if automatic, requestedProvider == nil {
            return await runAutomaticRecovery(trigger: .hostScheduler)
        }
        return await controller.login(requestedProvider: requestedProvider, automatic: automatic)
    }

    public func recoverAutomatically() async -> ProviderAuthResult {
        await runAutomaticRecovery(trigger: .hostScheduler)
    }

    /// Performs the explicitly acknowledged Dorm device-limit takeover. The
    /// caller is responsible for presenting confirmation; automatic lanes do
    /// not call this method.
    public func forceLogin(
        requestedProvider: CampusProviderID? = nil
    ) async -> ProviderAuthResult {
        await controller.forceLogin(requestedProvider: requestedProvider)
    }

    /// Executes a Provider logout through Core. Teaching remains subject to
    /// its existing Core safety gate (SRUN_LOGOUT_DISABLED).
    public func logout(providerID: CampusProviderID) async -> ProviderAuthResult {
        await controller.logout(providerID: providerID)
    }

    public func pauseAutomation() async throws {
        try await controller.pause()
    }

    public func resumeAutomation() async throws {
        try await controller.resume()
    }

    public func automationConfiguration() async throws -> CampusAutomationConfiguration {
        try await stateStore.automationConfiguration()
    }

    public func setProbeEnabled(_ enabled: Bool) async throws {
        try await stateStore.setProbeEnabled(enabled)
    }

    public func setProbeInterval(_ seconds: Int) async throws {
        try await stateStore.setProbeInterval(seconds)
    }

    public func execute(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider = .auto,
        interactive: Bool = false,
        timeoutSeconds: Int = 15
    ) async throws -> SZUNETCommandResult {
        guard enabled else { return .blocked(requestId: "embedded-disabled", code: "PROVIDER_DISABLED") }
        try Task.checkCancellation()
        let id = requestID()
        let timeout = min(max(timeoutSeconds, 1), 120)
        return await withTaskGroup(of: SZUNETCommandResult.self) { group in
            group.addTask { [self] in
                await executeEnabled(
                    command,
                    provider: provider,
                    interactive: interactive,
                    id: id
                )
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    return .blocked(requestId: id, code: "ADAPTER_TIMEOUT")
                } catch {
                    return .blocked(requestId: id, code: "OPERATION_CANCELLED")
                }
            }
            let completed = await group.next()
                ?? .blocked(requestId: id, code: "INTERNAL_ERROR")
            group.cancelAll()
            return completed
        }
    }

    private func executeEnabled(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider,
        interactive: Bool,
        id: String
    ) async -> SZUNETCommandResult {
        switch command {
        case .status, .check, .diagnostics:
            return await snapshotResult(id: id, snapshot: controller.refresh())
        case .login:
            return await actionResult(
                id: id,
                result: controller.login(requestedProvider: provider.coreProvider, automatic: false)
            )
        case .forceLogin:
            guard interactive else {
                return .blocked(requestId: id, code: "AUTH_NOT_CONFIRMED")
            }
            guard provider != .teaching else {
                return .blocked(
                    requestId: id,
                    code: "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED"
                )
            }
            return await actionResult(
                id: id,
                result: controller.forceLogin(requestedProvider: provider.coreProvider)
            )
        case .logout:
            let selected = await logoutProvider(provider)
            guard let selected else { return .blocked(requestId: id, code: "ENV_NON_CAMPUS") }
            return await actionResult(id: id, result: controller.logout(providerID: selected))
        case .pause:
            do { try await controller.pause() } catch { return .blocked(requestId: id, code: "INTERNAL_ERROR") }
        case .resume:
            do { try await controller.resume() } catch { return .blocked(requestId: id, code: "INTERNAL_ERROR") }
        case .enableProbe:
            do { try await stateStore.setProbeEnabled(true) } catch { return .blocked(requestId: id, code: "INTERNAL_ERROR") }
        case .disableProbe:
            do { try await stateStore.setProbeEnabled(false) } catch { return .blocked(requestId: id, code: "INTERNAL_ERROR") }
        case .probeEvery30Seconds, .probeEvery60Seconds, .probeEvery120Seconds, .probeEvery300Seconds:
            do { try await stateStore.setProbeInterval(command.probeInterval!) } catch { return .blocked(requestId: id, code: "INTERNAL_ERROR") }
        case .openSettings:
            break
        }
        return await snapshotResult(id: id, snapshot: controller.currentSnapshot(), outcome: .succeeded)
    }

    public func providerConfiguration() async throws -> CampusProductConfiguration {
        try await stateStore.loadProviderConfiguration()
    }

    public func updateProviderConfiguration(_ value: CampusProductConfiguration) async throws {
        try await controller.updateConfiguration(value)
    }

    public func savePassword(_ password: String, provider: CampusProviderID) async throws {
        try await stateStore.savePassword(password, provider: provider)
    }

    public func ownershipSnapshot() async throws -> CampusAutomationOwnershipSnapshot {
        try await stateStore.ownership(for: configuration.hostID)
    }

    public func takeAutomationOwnership() async throws -> CampusAutomationOwnershipSnapshot {
        let snapshot = try await stateStore.ownership(for: configuration.hostID)
        if let owner = snapshot.currentOwner, !owner.supportsOwnershipProtocol {
            let supportsProtocol = await capabilityChecker.supportsOwnershipProtocol(
                bundleIdentifier: owner.bundleID
            )
            _ = try await stateStore.refreshOwnerCapability(
                hostID: owner.hostID,
                supportsOwnershipProtocol: supportsProtocol
            )
            guard supportsProtocol else {
                throw CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(owner.displayName)
            }
        }
        return try await stateStore.transferOwnership(to: host)
    }

    public func releaseAutomationOwnership() async throws -> CampusAutomationOwnershipSnapshot {
        try await stateStore.releaseOwnership(from: configuration.hostID)
    }

    public func networkDidChange() async {
        guard enabled else { return }
        await controller.networkChanged()
        if configuration.managesFallbackScheduling {
            await performAutomaticRecoveryIfEligible(trigger: .networkChange)
        }
    }

    public func networkChanged() async { await networkDidChange() }

    public func wake() async -> SZUNETCommandResult {
        guard enabled else { return .blocked(requestId: "embedded-disabled", code: "PROVIDER_DISABLED") }
        if configuration.managesFallbackScheduling {
            await performAutomaticRecoveryIfEligible(trigger: .wake)
        }
        return await executeIgnoringFailure(.status)
    }

    public func shutdown() async throws {
        fallbackTask?.cancel(); fallbackTask = nil
        guard enabled else { return }
        let ownership = try await stateStore.ownership(for: configuration.hostID)
        if ownership.isCurrentHostOwner {
            _ = try await stateStore.setOwnerRunning(false, hostID: configuration.hostID)
        }
        enabled = false
    }

    public func disableAndReleaseOwnership() async throws {
        fallbackTask?.cancel(); fallbackTask = nil
        guard enabled else { return }
        let ownership = try await stateStore.ownership(for: configuration.hostID)
        if ownership.isCurrentHostOwner { _ = try await stateStore.releaseOwnership(from: configuration.hostID) }
        enabled = false
    }

    private func executeIgnoringFailure(_ command: SZUNETCommand) async -> SZUNETCommandResult {
        (try? await execute(command, provider: .auto, interactive: false, timeoutSeconds: 15))
            ?? .blocked(requestId: "embedded-error", code: "INTERNAL_ERROR")
    }

    private func logoutProvider(_ provider: SZUNETCommandProvider) async -> CampusProviderID? {
        if let selected = provider.coreProvider { return selected }
        return switch await controller.refresh().category {
        case .dorm: .dorm
        case .teaching: .teaching
        case .ambiguous, .nonCampus, .unknown: nil
        }
    }

    private func snapshotResult(
        id: String,
        snapshot: CampusProductSnapshot,
        outcome: SZUNETOutcome = .unchanged
    ) async -> SZUNETCommandResult {
        let automation = try? await stateStore.automationConfiguration()
        let ownership = try? await stateStore.ownership(for: configuration.hostID)
        let provider: SZUNETResultProvider = switch snapshot.category {
        case .dorm: .dorm
        case .teaching: .teaching
        case .ambiguous, .nonCampus, .unknown: .auto
        }
        let state: SZUNETSessionState = switch snapshot.category {
        case .dorm: .init(core: snapshot.dorm.lifecycle)
        case .teaching: .init(core: snapshot.teaching.lifecycle)
        case .ambiguous, .nonCampus, .unknown: .unknown
        }
        return SZUNETCommandResult(
            requestId: id,
            outcome: outcome,
            provider: provider,
            networkContext: .init(core: snapshot.category),
            sessionState: state,
            errorCode: snapshot.lastErrorCode,
            automaticEnabled: snapshot.automaticEnabled,
            ownerAppRunning: ownership?.ownerRunning,
            networkProbeEnabled: automation?.networkProbeEnabled,
            probeIntervalSeconds: automation?.probeIntervalSeconds,
            onlineDeviceCount: snapshot.onlineDeviceCount,
            onlineDeviceLimit: snapshot.onlineDeviceLimit,
            observedAt: Date()
        )
    }

    private func actionResult(id: String, result: ProviderAuthResult) async -> SZUNETCommandResult {
        let snapshot = await controller.currentSnapshot()
        let automation = try? await stateStore.automationConfiguration()
        let ownership = try? await stateStore.ownership(for: configuration.hostID)
        return SZUNETCommandResult(
            requestId: id,
            outcome: .init(core: result.outcome),
            provider: result.providerID == .dorm ? .dorm : .teaching,
            networkContext: .init(core: snapshot.category),
            sessionState: .init(core: result.sessionState.rawValue),
            errorCode: result.errorCode,
            retryable: result.retryable,
            automaticEnabled: snapshot.automaticEnabled,
            ownerAppRunning: ownership?.ownerRunning,
            networkProbeEnabled: automation?.networkProbeEnabled,
            probeIntervalSeconds: automation?.probeIntervalSeconds,
            onlineDeviceCount: result.onlineDeviceCount,
            onlineDeviceLimit: result.onlineDeviceLimit,
            observedAt: Date()
        )
    }

    private var host: CampusAutomationHost {
        CampusAutomationHost(
            hostID: configuration.hostID,
            displayName: configuration.displayName,
            bundleID: configuration.bundleIdentifier
        )
    }

    private func scheduleFallback() {
        guard configuration.managesFallbackScheduling else {
            fallbackTask?.cancel()
            fallbackTask = nil
            return
        }
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let automation = try? await self.stateStore.automationConfiguration()
                let interval = automation?.probeIntervalSeconds
                    ?? CampusAutomationPreferences.defaultProbeIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
                if !Task.isCancelled {
                    await self.performAutomaticRecoveryIfEligible(trigger: .periodic)
                }
            }
        }
    }

    private func performAutomaticRecoveryIfEligible(trigger: AutomaticRecoveryTrigger) async {
        guard enabled,
              let automation = try? await stateStore.automationConfiguration(),
              automation.networkProbeEnabled,
              let product = try? await stateStore.loadProviderConfiguration(),
              product.automaticEnabled,
              (try? await stateStore.verifyOwnership(hostID: configuration.hostID)) == true else { return }
        _ = await runAutomaticRecovery(trigger: trigger)
    }

    private func runAutomaticRecovery(
        trigger: AutomaticRecoveryTrigger
    ) async -> ProviderAuthResult {
        guard !recoveryInProgress else {
            return .blocked(.dorm, "OPERATION_IN_PROGRESS")
        }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        let result = await controller.recoverAutomatically()
        let count = result.onlineDeviceCount.map(String.init) ?? "unknown"
        let limit = result.onlineDeviceLimit.map(String.init) ?? "unknown"
        let resultCode = result.errorCode ?? "none"
        logger.info(
            "automatic_recovery trigger=\(trigger.rawValue) "
                + "session=\(result.sessionState.rawValue) devices=\(count)/\(limit) "
                + "outcome=\(result.outcome.rawValue) result=\(resultCode)"
        )
        return result
    }
}

private enum AutomaticRecoveryTrigger: String {
    case networkChange = "network-change"
    case periodic
    case wake
    case hostScheduler = "host-scheduler"
}

private extension SZUNETCommandProvider {
    var coreProvider: CampusProviderID? {
        switch self { case .auto: nil; case .dorm: .dorm; case .teaching: .teaching }
    }
}

private extension SZUNETCommand {
    var probeInterval: Int? {
        switch self {
        case .probeEvery30Seconds: 30
        case .probeEvery60Seconds: 60
        case .probeEvery120Seconds: 120
        case .probeEvery300Seconds: 300
        default: nil
        }
    }
}

private extension SZUNETNetworkContext {
    init(core: CampusNetworkCategory) {
        self = switch core {
        case .dorm: .dorm; case .teaching: .teaching; case .nonCampus: .nonCampus
        case .ambiguous: .ambiguous; case .unknown: .unknown
        }
    }
}

private extension SZUNETSessionState {
    init(core: String) { self = SZUNETSessionState(rawValue: core) ?? .unknown }
}

private extension SZUNETOutcome {
    init(core: ProviderAuthOutcome) {
        self = switch core {
        case .succeeded: .succeeded; case .unchanged: .unchanged; case .failed: .failed
        case .cancelled: .cancelled; case .blocked: .blocked
        }
    }
}
