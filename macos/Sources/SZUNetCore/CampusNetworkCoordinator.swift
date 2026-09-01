import Foundation

public struct CampusCoordinatorSettings: Equatable, Sendable {
    public var dormEnabled: Bool
    public var teachingEnabled: Bool
    public var automaticEnabled: Bool

    public init(
        dormEnabled: Bool = true,
        teachingEnabled: Bool = false,
        automaticEnabled: Bool = true
    ) {
        self.dormEnabled = dormEnabled
        self.teachingEnabled = teachingEnabled
        self.automaticEnabled = automaticEnabled
    }

    func isEnabled(_ providerID: CampusProviderID) -> Bool {
        providerID == .dorm ? dormEnabled : teachingEnabled
    }
}

public enum CampusCoordinatorState: Equatable, Sendable {
    case idle
    case probing(UInt64)
    case ambiguous
    case nonCampus
    case checkingSession(CampusProviderID)
    case online(CampusProviderID)
    case offline(CampusProviderID)
    case authorizingCredentialUse(CampusProviderID)
    case loggingIn(CampusProviderID)
    case backingOff(CampusProviderID, Date)
    case cancelled
    case fatal(CampusProviderID, String)
}

public struct CampusCoordinatorStatus: Equatable, Sendable {
    public var providerID: CampusProviderID?
    public var session: ProviderSessionResult?
    public var errorCode: String?

    public init(
        providerID: CampusProviderID? = nil,
        session: ProviderSessionResult? = nil,
        errorCode: String? = nil
    ) {
        self.providerID = providerID
        self.session = session
        self.errorCode = errorCode
    }
}

public actor CampusNetworkCoordinator {
    public private(set) var state: CampusCoordinatorState = .idle
    public private(set) var generation: UInt64
    public private(set) var settings: CampusCoordinatorSettings

    private let providers: [any NetworkAuthProvider]
    private let credentialBroker: any CampusCredentialBroker
    private let clock: @Sendable () -> Date
    private let jitterFraction: @Sendable () -> Double
    private let operationLock: AuthenticationOperationLock
    private var activeTask: Task<ProviderAuthResult, Never>?
    private var activeLease: AuthenticationOperationLease?
    private var activeID: UUID?
    private var statusInProgress = false
    private var failureCounts: [CampusProviderID: Int] = [:]
    private var backoffUntil: [CampusProviderID: Date] = [:]
    private var fatalErrors: [CampusProviderID: String] = [:]

    public init(
        providers: [any NetworkAuthProvider],
        credentialBroker: any CampusCredentialBroker,
        generation: UInt64 = 0,
        settings: CampusCoordinatorSettings = .init(),
        clock: @escaping @Sendable () -> Date = { Date() },
        jitterFraction: @escaping @Sendable () -> Double = { 0 },
        authenticationLockURL: URL = AppPaths.standard.authenticationLockFile
    ) {
        self.providers = providers
        self.credentialBroker = credentialBroker
        self.generation = generation
        self.settings = settings
        self.clock = clock
        self.jitterFraction = jitterFraction
        operationLock = AuthenticationOperationLock(url: authenticationLockURL)
    }

    public func updateSettings(_ settings: CampusCoordinatorSettings) {
        self.settings = settings
    }

    public func networkChanged(to newGeneration: UInt64) async {
        guard newGeneration != generation else { return }
        let oldGeneration = generation
        generation = newGeneration
        activeTask?.cancel()
        failureCounts.removeAll()
        backoffUntil.removeAll()
        state = .cancelled
        for provider in providers {
            await provider.cancelPendingOperations(generation: oldGeneration)
        }
    }

    public func login(
        context: CampusNetworkContext,
        username: String,
        requestedProvider: CampusProviderID? = nil,
        automatic: Bool = false,
        credentialAuthorization: (@Sendable () async -> Bool)? = nil
    ) async -> ProviderAuthResult {
        return await executeLogin(
            context: context,
            username: username,
            requestedProvider: requestedProvider,
            automatic: automatic,
            allowDeviceReplacement: false,
            allowMissingExactDormSession: false,
            credentialAuthorization: credentialAuthorization
        )
    }

    /// Re-evaluates a Dorm session after a source-bound, proxy-free external
    /// probe failed. This path may treat an authoritative missing exact online
    /// record as recoverable, but it never replaces another device.
    public func recoverStaleDormSession(
        context: CampusNetworkContext,
        username: String,
        credentialAuthorization: (@Sendable () async -> Bool)? = nil
    ) async -> ProviderAuthResult {
        await executeLogin(
            context: context,
            username: username,
            requestedProvider: .dorm,
            automatic: true,
            allowDeviceReplacement: false,
            allowMissingExactDormSession: true,
            credentialAuthorization: credentialAuthorization
        )
    }

    /// Performs an explicitly confirmed Dorm session replacement.  This path
    /// is intentionally separate from `login` so automatic callers cannot
    /// accidentally opt into evicting another device.
    public func forceLogin(
        context: CampusNetworkContext,
        username: String,
        requestedProvider: CampusProviderID? = nil
    ) async -> ProviderAuthResult {
        guard requestedProvider == nil || requestedProvider == .dorm else {
            return .blocked(
                requestedProvider ?? .dorm,
                "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED"
            )
        }
        return await executeLogin(
            context: context,
            username: username,
            requestedProvider: requestedProvider,
            automatic: false,
            allowDeviceReplacement: true,
            allowMissingExactDormSession: false,
            credentialAuthorization: nil
        )
    }

    private func executeLogin(
        context: CampusNetworkContext,
        username: String,
        requestedProvider: CampusProviderID?,
        automatic: Bool,
        allowDeviceReplacement: Bool,
        allowMissingExactDormSession: Bool,
        credentialAuthorization: (@Sendable () async -> Bool)?
    ) async -> ProviderAuthResult {
        guard context.generation == generation else {
            return .blocked(requestedProvider ?? .dorm, "ENV_NETWORK_CHANGED")
        }
        guard activeTask == nil, !statusInProgress else {
            return .blocked(requestedProvider ?? .dorm, "OPERATION_IN_PROGRESS")
        }
        let lease: AuthenticationOperationLease
        do {
            guard let acquired = try operationLock.tryAcquire() else {
                return .blocked(requestedProvider ?? .dorm, "OPERATION_IN_PROGRESS")
            }
            lease = acquired
        } catch {
            return .blocked(requestedProvider ?? .dorm, "OPERATION_IN_PROGRESS")
        }
        if automatic, !settings.automaticEnabled {
            return .blocked(requestedProvider ?? .dorm, "PROVIDER_DISABLED")
        }
        state = .probing(generation)
        let operationID = UUID()
        let currentSettings = settings
        let fatalSnapshot = fatalErrors
        let backoffSnapshot = backoffUntil
        let now = clock()
        let task = Task { [providers, credentialBroker] in
            await Self.performLogin(
                providers: providers,
                broker: credentialBroker,
                context: context,
                username: username,
                requestedProvider: requestedProvider,
                settings: currentSettings,
                fatalErrors: fatalSnapshot,
                backoffUntil: backoffSnapshot,
                now: now,
                allowDeviceReplacement: allowDeviceReplacement,
                allowMissingExactDormSession: allowMissingExactDormSession,
                credentialAuthorization: credentialAuthorization
            )
        }
        activeTask = task
        activeLease = lease
        activeID = operationID
        let result = await task.value
        if activeID == operationID {
            activeTask = nil
            activeID = nil
            activeLease?.release()
            activeLease = nil
        }
        guard context.generation == generation, !Task.isCancelled else {
            state = .cancelled
            return ProviderAuthResult(
                outcome: .cancelled,
                providerID: result.providerID,
                errorCode: "ENV_NETWORK_CHANGED"
            )
        }
        apply(result)
        return result
    }

    public func logout(
        context: CampusNetworkContext,
        username: String,
        providerID: CampusProviderID
    ) async -> ProviderAuthResult {
        guard context.generation == generation else {
            return .blocked(providerID, "ENV_NETWORK_CHANGED")
        }
        guard settings.isEnabled(providerID),
              let provider = providers.first(where: { $0.providerID == providerID }) else {
            return .blocked(providerID, "PROVIDER_DISABLED")
        }
        guard activeTask == nil, !statusInProgress else {
            return .blocked(providerID, "OPERATION_IN_PROGRESS")
        }
        let lease: AuthenticationOperationLease
        do {
            guard let acquired = try operationLock.tryAcquire() else {
                return .blocked(providerID, "OPERATION_IN_PROGRESS")
            }
            lease = acquired
        } catch {
            return .blocked(providerID, "OPERATION_IN_PROGRESS")
        }
        let operationID = UUID()
        let task = Task {
            let probe = await provider.probeEnvironment(context)
            guard !Task.isCancelled else { return Self.cancelled(providerID) }
            guard probe.isVerified else {
                return .blocked(providerID, probe.errorCode ?? "ENV_AMBIGUOUS")
            }
            return await provider.logout(context, probe: probe, username: username)
        }
        activeTask = task
        activeLease = lease
        activeID = operationID
        let result = await task.value
        if activeID == operationID {
            activeTask = nil
            activeID = nil
            activeLease?.release()
            activeLease = nil
        }
        guard context.generation == generation else {
            return ProviderAuthResult(outcome: .cancelled, providerID: providerID, errorCode: "ENV_NETWORK_CHANGED")
        }
        return result
    }

    public func status(
        context: CampusNetworkContext,
        usernames: [CampusProviderID: String]
    ) async -> CampusCoordinatorStatus {
        guard context.generation == generation else {
            return CampusCoordinatorStatus(errorCode: "ENV_NETWORK_CHANGED")
        }
        guard activeTask == nil, !statusInProgress else {
            return CampusCoordinatorStatus(errorCode: "OPERATION_IN_PROGRESS")
        }
        let lease: AuthenticationOperationLease
        do {
            guard let acquired = try operationLock.tryAcquire() else {
                return CampusCoordinatorStatus(errorCode: "OPERATION_IN_PROGRESS")
            }
            lease = acquired
        } catch {
            return CampusCoordinatorStatus(errorCode: "OPERATION_IN_PROGRESS")
        }
        statusInProgress = true
        defer {
            statusInProgress = false
            lease.release()
        }

        var verified: [(any NetworkAuthProvider, ProviderProbe)] = []
        var sawAmbiguous = false
        for provider in providers where settings.isEnabled(provider.providerID) {
            guard !Task.isCancelled else {
                return CampusCoordinatorStatus(errorCode: "OPERATION_CANCELLED")
            }
            let probe = await provider.probeEnvironment(context)
            if probe.support == .ambiguous { sawAmbiguous = true }
            if probe.isVerified { verified.append((provider, probe)) }
        }
        guard context.generation == generation else {
            return CampusCoordinatorStatus(errorCode: "ENV_NETWORK_CHANGED")
        }
        guard !sawAmbiguous, verified.count <= 1 else {
            state = .ambiguous
            return CampusCoordinatorStatus(errorCode: "ENV_AMBIGUOUS")
        }
        guard let (provider, probe) = verified.first else {
            state = .nonCampus
            let anyEnabled = settings.dormEnabled || settings.teachingEnabled
            return CampusCoordinatorStatus(
                errorCode: anyEnabled ? "ENV_NON_CAMPUS" : "PROVIDER_DISABLED"
            )
        }
        state = .checkingSession(provider.providerID)
        let session = await provider.sessionStatus(
            context,
            probe: probe,
            username: usernames[provider.providerID] ?? ""
        )
        guard context.generation == generation, !Task.isCancelled else {
            state = .cancelled
            return CampusCoordinatorStatus(
                providerID: provider.providerID,
                errorCode: "ENV_NETWORK_CHANGED"
            )
        }
        switch session.state {
        case .online: state = .online(provider.providerID)
        case .offline: state = .offline(provider.providerID)
        case .unknown, .blocked: state = .idle
        }
        return CampusCoordinatorStatus(
            providerID: provider.providerID,
            session: session,
            errorCode: session.errorCode
        )
    }

    private static func performLogin(
        providers: [any NetworkAuthProvider],
        broker: any CampusCredentialBroker,
        context: CampusNetworkContext,
        username: String,
        requestedProvider: CampusProviderID?,
        settings: CampusCoordinatorSettings,
        fatalErrors: [CampusProviderID: String],
        backoffUntil: [CampusProviderID: Date],
        now: Date,
        allowDeviceReplacement: Bool,
        allowMissingExactDormSession: Bool,
        credentialAuthorization: (@Sendable () async -> Bool)?
    ) async -> ProviderAuthResult {
        var probes: [ProviderProbe] = []
        for provider in providers {
            guard !Task.isCancelled else { return cancelled(requestedProvider ?? provider.providerID) }
            probes.append(await provider.probeEnvironment(context))
        }
        guard !Task.isCancelled else { return cancelled(requestedProvider ?? .dorm) }
        let verified = probes.filter(\.isVerified)
        if probes.contains(where: { $0.support == .ambiguous }) || verified.count > 1 {
            return .blocked(requestedProvider ?? verified.first?.providerID ?? .dorm, "ENV_AMBIGUOUS")
        }
        guard let probe = verified.first else {
            let uncertain = probes.contains { $0.confidence != .verified && $0.support != .unsupported }
            return .blocked(requestedProvider ?? .dorm, uncertain ? "ENV_AMBIGUOUS" : "ENV_NON_CAMPUS")
        }
        if let requestedProvider, requestedProvider != probe.providerID {
            return .blocked(requestedProvider, "ENV_AMBIGUOUS")
        }
        guard settings.isEnabled(probe.providerID) else {
            return .blocked(probe.providerID, "PROVIDER_DISABLED")
        }
        if let fatal = fatalErrors[probe.providerID] {
            return .blocked(probe.providerID, fatal)
        }
        if let until = backoffUntil[probe.providerID], now < until {
            return .blocked(probe.providerID, "PROVIDER_BACKING_OFF")
        }
        guard let provider = providers.first(where: { $0.providerID == probe.providerID }) else {
            return .blocked(probe.providerID, "INTERNAL_ERROR")
        }
        let session = await provider.sessionStatus(context, probe: probe, username: username)
        guard !Task.isCancelled else { return cancelled(probe.providerID) }
        if allowMissingExactDormSession {
            guard probe.providerID == .dorm else {
                return .blocked(probe.providerID, "PROVIDER_DISABLED", session: session)
            }
            switch session.exactOnlineRecordPresent {
            case .some(true):
                return .blocked(
                    probe.providerID,
                    "NET_CAMPUS_EGRESS_UNAVAILABLE",
                    session: session
                )
            case .some(false):
                guard session.accountMatch != .differs,
                      session.onlineDeviceCount != nil,
                      session.onlineDeviceLimit == CampusOnlineDevicePolicy.dormLimit else {
                    return .blocked(probe.providerID, "SESSION_UNKNOWN", session: session)
                }
            case .none:
                return .blocked(probe.providerID, "SESSION_UNKNOWN", session: session)
            }
        } else {
            if session.state == .online, session.accountMatch == .matches {
                return ProviderAuthResult(
                    outcome: .unchanged,
                    providerID: probe.providerID,
                    sessionState: .online,
                    accountMatch: .matches,
                    clientIP: session.clientIP,
                    onlineDeviceCount: session.onlineDeviceCount,
                    onlineDeviceLimit: session.onlineDeviceLimit,
                    errorCode: "SESSION_ONLINE"
                )
            }
            guard session.state == .offline else {
                return .blocked(
                    probe.providerID,
                    session.errorCode ?? "SESSION_UNKNOWN",
                    session: session
                )
            }
        }

        // A real Dorm provider always reports the fixed limit even when the
        // portal list itself is unavailable.  That combination (known policy,
        // unknown count) is fail-closed and must never fall through to a
        // credential read.  Legacy provider doubles that predate the count
        // fields leave both values nil and retain their existing behavior.
        if probe.providerID == .dorm,
           session.onlineDeviceLimit != nil,
           session.onlineDeviceCount == nil {
            return .blocked(probe.providerID, "SESSION_UNKNOWN", session: session)
        }

        // A Dorm count is authoritative only when the portal supplied both
        // values.  Unknown counts are handled by the provider as an unknown
        // session and never reach credential access.  The fixed policy fallback
        // keeps compatibility with older provider implementations that expose
        // only the optional count field.
        let configuredLimit = session.onlineDeviceLimit ?? CampusOnlineDevicePolicy.dormLimit
        let confirmedAtDeviceLimit = probe.providerID == .dorm
            && configuredLimit == CampusOnlineDevicePolicy.dormLimit
            && session.onlineDeviceCount.map { $0 >= configuredLimit } == true
        let atDeviceLimit = confirmedAtDeviceLimit
            || session.errorCode == "AUTH_DEVICE_LIMIT"
        if atDeviceLimit {
            guard allowDeviceReplacement else {
                return .blocked(probe.providerID, "AUTH_DEVICE_LIMIT", session: session)
            }
            guard confirmedAtDeviceLimit else {
                return .blocked(
                    probe.providerID,
                    "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED",
                    session: session
                )
            }
        } else if allowDeviceReplacement {
            // Force replacement is not a general login bypass.  Requiring a
            // confirmed Dorm 3/3 result prevents callers from using it to skip
            // an ordinary session or environment gate.
            return .blocked(
                probe.providerID,
                "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED",
                session: session
            )
        }
        if let credentialAuthorization, !(await credentialAuthorization()) {
            return .blocked(probe.providerID, "AUTOMATION_OWNER_CONFLICT")
        }
        let credential: CredentialHandle
        do {
            guard let opened = try await broker.openCredential(
                for: probe.providerID,
                username: username
            ) else {
                return .blocked(probe.providerID, "CRED_MISSING")
            }
            credential = opened
        } catch {
            return .blocked(probe.providerID, "CRED_STORE_FAILURE")
        }
        guard !Task.isCancelled else { return cancelled(probe.providerID) }
        let result = await provider.login(
            context,
            probe: probe,
            username: username,
            credential: credential
        )
        guard !Task.isCancelled else { return cancelled(probe.providerID) }
        return result
    }

    private func apply(_ result: ProviderAuthResult) {
        let providerID = result.providerID
        if result.outcome == .succeeded || result.outcome == .unchanged {
            failureCounts[providerID] = nil
            backoffUntil[providerID] = nil
            state = result.sessionState == .online ? .online(providerID) : .idle
            return
        }
        if Self.fatalCodes.contains(result.errorCode ?? "") {
            let code = result.errorCode ?? "INTERNAL_ERROR"
            fatalErrors[providerID] = code
            state = .fatal(providerID, code)
            return
        }
        if result.retryable {
            let count = (failureCounts[providerID] ?? 0) + 1
            failureCounts[providerID] = count
            let delays: [TimeInterval] = [120, 300, 600, 900]
            let base = delays[min(count - 1, delays.count - 1)]
            let jitter = min(0.15, max(0, jitterFraction()))
            let until = clock().addingTimeInterval(base * (1 + jitter))
            backoffUntil[providerID] = until
            state = .backingOff(providerID, until)
            return
        }
        state = result.outcome == .cancelled ? .cancelled : .idle
    }

    private static func cancelled(_ providerID: CampusProviderID) -> ProviderAuthResult {
        ProviderAuthResult(
            outcome: .cancelled,
            providerID: providerID,
            errorCode: "OPERATION_CANCELLED"
        )
    }

    private static let fatalCodes: Set<String> = [
        "AUTH_BAD_PASSWORD", "AUTH_ACCOUNT_NOT_FOUND",
        "AUTH_ACCOUNT_BLOCKED", "AUTH_PRODUCT_SUFFIX_INVALID", "NET_TLS_FAILED",
        "CRED_STORE_FAILURE", "CRED_MIGRATION_REQUIRED",
    ]
}
