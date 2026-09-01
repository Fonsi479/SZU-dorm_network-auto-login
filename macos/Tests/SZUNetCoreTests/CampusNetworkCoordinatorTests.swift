import Foundation
import Testing
@testable import SZUNetCore

@Suite("Campus network coordinator", .serialized)
struct CampusNetworkCoordinatorTests {
    @Test("teaching is disabled by default and all four provider toggle combinations are deterministic")
    func fourToggleCombinations() async {
        let disabledTeaching = await runSingle(
            providerID: .teaching,
            settings: .init(),
            context: context(teaching: true)
        )
        #expect(disabledTeaching.result.errorCode == "PROVIDER_DISABLED")
        #expect(disabledTeaching.credentialReads == 0)

        let bothOff = await runSingle(
            providerID: .dorm,
            settings: .init(dormEnabled: false, teachingEnabled: false),
            context: context(dorm: true)
        )
        #expect(bothOff.result.errorCode == "PROVIDER_DISABLED")
        #expect(bothOff.credentialReads == 0)

        let dormOnly = await runSingle(
            providerID: .dorm,
            settings: .init(dormEnabled: true, teachingEnabled: false),
            context: context(dorm: true)
        )
        #expect(dormOnly.result.outcome == .succeeded)
        #expect((dormOnly.credentialReads, dormOnly.loginCalls) == (1, 1))

        let teachingOnly = await runSingle(
            providerID: .teaching,
            settings: .init(dormEnabled: false, teachingEnabled: true),
            context: context(teaching: true)
        )
        #expect(teachingOnly.result.outcome == .succeeded)
        #expect((teachingOnly.credentialReads, teachingOnly.loginCalls) == (1, 1))

        let bothOnUnique = await runSingle(
            providerID: .teaching,
            settings: .init(dormEnabled: true, teachingEnabled: true),
            context: context(teaching: true)
        )
        #expect(bothOnUnique.result.outcome == .succeeded)
        #expect((bothOnUnique.credentialReads, bothOnUnique.loginCalls) == (1, 1))
    }

    @Test("two verified providers are ambiguous with zero credential reads or logins")
    func twoVerifiedIsAmbiguous() async {
        let dorm = CoordinatorStubProvider(.dorm)
        let teaching = CoordinatorStubProvider(.teaching)
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(
            providers: [dorm, teaching],
            credentialBroker: broker,
            settings: .init(dormEnabled: true, teachingEnabled: true)
        )

        let result = await coordinator.login(
            context: context(dorm: true, teaching: true),
            username: "synthetic"
        )

        #expect(result.errorCode == "ENV_AMBIGUOUS")
        #expect(await broker.readCount == 0)
        #expect(await dorm.loginCount == 0)
        #expect(await teaching.loginCount == 0)
    }

    @Test("unknown, already-online, and disabled states perform zero credential reads")
    func nonOfflineStatesReadNoCredential() async {
        for session in [ProviderSessionState.unknown, .online] {
            let provider = CoordinatorStubProvider(.dorm, session: session)
            let broker = CoordinatorCredentialBroker()
            let coordinator = CampusNetworkCoordinator(providers: [provider], credentialBroker: broker)
            let result = await coordinator.login(context: context(dorm: true), username: "synthetic")

            #expect(await broker.readCount == 0)
            #expect(await provider.loginCount == 0)
            if session == .unknown {
                #expect(result.errorCode == "SESSION_UNKNOWN")
            } else {
                #expect(result.outcome == .unchanged)
            }
        }
    }

    @Test("Dorm 3/3 blocks manual and automatic login before credential access")
    func deviceLimitBlocksNormalAndAutomaticLogin() async {
        for automatic in [false, true] {
            let provider = CoordinatorStubProvider(
                .dorm,
                onlineDeviceCount: 3,
                onlineDeviceLimit: 3
            )
            let broker = CoordinatorCredentialBroker()
            let coordinator = CampusNetworkCoordinator(
                providers: [provider],
                credentialBroker: broker
            )
            let result = await coordinator.login(
                context: context(dorm: true),
                username: "synthetic",
                automatic: automatic
            )

            #expect(result.outcome == .blocked)
            #expect(result.errorCode == "AUTH_DEVICE_LIMIT")
            #expect(result.onlineDeviceCount == 3)
            #expect(result.onlineDeviceLimit == 3)
            #expect(await broker.readCount == 0)
            #expect(await provider.loginCount == 0)
        }
    }

    @Test("force login bypasses only a confirmed Dorm 3/3 gate")
    func forceLoginRequiresDormDeviceLimit() async {
        let provider = CoordinatorStubProvider(
            .dorm,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(
            providers: [provider],
            credentialBroker: broker
        )
        let forced = await coordinator.forceLogin(
            context: context(dorm: true),
            username: "synthetic",
            requestedProvider: .dorm
        )
        #expect(forced.outcome == .succeeded)
        #expect(await broker.readCount == 1)
        #expect(await provider.loginCount == 1)

        let belowLimitProvider = CoordinatorStubProvider(
            .dorm,
            onlineDeviceCount: 2,
            onlineDeviceLimit: 3
        )
        let belowLimitBroker = CoordinatorCredentialBroker()
        let belowLimitCoordinator = CampusNetworkCoordinator(
            providers: [belowLimitProvider],
            credentialBroker: belowLimitBroker
        )
        let belowLimit = await belowLimitCoordinator.forceLogin(
            context: context(dorm: true),
            username: "synthetic"
        )
        #expect(belowLimit.errorCode == "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED")
        #expect(await belowLimitBroker.readCount == 0)
        #expect(await belowLimitProvider.loginCount == 0)

        let teaching = CoordinatorStubProvider(
            .teaching,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )
        let teachingBroker = CoordinatorCredentialBroker()
        let teachingCoordinator = CampusNetworkCoordinator(
            providers: [teaching],
            credentialBroker: teachingBroker,
            settings: .init(dormEnabled: false, teachingEnabled: true)
        )
        let teachingResult = await teachingCoordinator.forceLogin(
            context: context(teaching: true),
            username: "synthetic",
            requestedProvider: .teaching
        )
        #expect(teachingResult.errorCode == "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED")
        #expect(await teachingBroker.readCount == 0)
        #expect(await teaching.loginCount == 0)
    }

    @Test("Dorm unknown device count fails closed before credentials")
    func unknownDormDeviceCountBlocksLogin() async {
        let provider = CoordinatorStubProvider(
            .dorm,
            onlineDeviceCount: nil,
            onlineDeviceLimit: 3
        )
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(
            providers: [provider],
            credentialBroker: broker
        )

        let result = await coordinator.login(
            context: context(dorm: true),
            username: "synthetic"
        )

        #expect(result.errorCode == "SESSION_UNKNOWN")
        #expect(await broker.readCount == 0)
        #expect(await provider.loginCount == 0)
    }

    @Test("stale Dorm recovery requires authoritative missing local record")
    func staleDormRecoveryEvidenceGate() async {
        let present = RecoveryProviderStub(sessions: [
            ProviderSessionResult(
                state: .online,
                accountMatch: .matches,
                exactOnlineRecordPresent: true,
                onlineDeviceCount: 2,
                onlineDeviceLimit: 3
            ),
        ])
        let presentBroker = CoordinatorCredentialBroker()
        let presentCoordinator = CampusNetworkCoordinator(
            providers: [present],
            credentialBroker: presentBroker
        )
        let presentResult = await presentCoordinator.recoverStaleDormSession(
            context: context(dorm: true),
            username: "synthetic"
        )
        #expect(presentResult.errorCode == "NET_CAMPUS_EGRESS_UNAVAILABLE")
        #expect(await presentBroker.readCount == 0)
        #expect(await present.loginCount == 0)

        let missing = RecoveryProviderStub(sessions: [
            ProviderSessionResult(
                state: .unknown,
                accountMatch: .matches,
                exactOnlineRecordPresent: false,
                onlineDeviceCount: 2,
                onlineDeviceLimit: 3,
                errorCode: "SESSION_UNKNOWN"
            ),
        ])
        let missingBroker = CoordinatorCredentialBroker()
        let missingCoordinator = CampusNetworkCoordinator(
            providers: [missing],
            credentialBroker: missingBroker
        )
        let missingResult = await missingCoordinator.recoverStaleDormSession(
            context: context(dorm: true),
            username: "synthetic"
        )
        #expect(missingResult.outcome == .succeeded)
        #expect(await missingBroker.readCount == 1)
        #expect(await missing.loginCount == 1)
    }

    @Test("stale recovery blocks unknown count and rechecks a dynamic 3/3 limit")
    func staleDormRecoveryRechecksDynamicLimit() async {
        let unknown = RecoveryProviderStub(sessions: [
            ProviderSessionResult(
                state: .unknown,
                accountMatch: .matches,
                exactOnlineRecordPresent: false,
                onlineDeviceCount: nil,
                onlineDeviceLimit: 3,
                errorCode: "SESSION_UNKNOWN"
            ),
        ])
        let unknownBroker = CoordinatorCredentialBroker()
        let unknownCoordinator = CampusNetworkCoordinator(
            providers: [unknown],
            credentialBroker: unknownBroker
        )
        let unknownResult = await unknownCoordinator.recoverStaleDormSession(
            context: context(dorm: true),
            username: "synthetic"
        )
        #expect(unknownResult.errorCode == "SESSION_UNKNOWN")
        #expect(await unknownBroker.readCount == 0)

        let changing = RecoveryProviderStub(sessions: [
            ProviderSessionResult(
                state: .unknown,
                accountMatch: .matches,
                exactOnlineRecordPresent: false,
                onlineDeviceCount: 3,
                onlineDeviceLimit: 3,
                errorCode: "SESSION_UNKNOWN"
            ),
            ProviderSessionResult(
                state: .unknown,
                accountMatch: .matches,
                exactOnlineRecordPresent: false,
                onlineDeviceCount: 2,
                onlineDeviceLimit: 3,
                errorCode: "SESSION_UNKNOWN"
            ),
        ])
        let changingBroker = CoordinatorCredentialBroker()
        let changingCoordinator = CampusNetworkCoordinator(
            providers: [changing],
            credentialBroker: changingBroker
        )
        let full = await changingCoordinator.recoverStaleDormSession(
            context: context(dorm: true),
            username: "synthetic"
        )
        let available = await changingCoordinator.recoverStaleDormSession(
            context: context(dorm: true),
            username: "synthetic"
        )
        #expect(full.errorCode == "AUTH_DEVICE_LIMIT")
        #expect(available.outcome == .succeeded)
        #expect(await changingBroker.readCount == 1)
        #expect(await changing.loginCount == 1)
    }

    @Test("automatic login reauthorizes ownership immediately before credential access")
    func automaticLoginCredentialAuthorization() async {
        let provider = CoordinatorStubProvider(.dorm)
        let broker = CoordinatorCredentialBroker()
        let authorization = CoordinatorCredentialAuthorization(allowed: false)
        let coordinator = CampusNetworkCoordinator(
            providers: [provider],
            credentialBroker: broker
        )

        let result = await coordinator.login(
            context: context(dorm: true),
            username: "synthetic",
            automatic: true,
            credentialAuthorization: { await authorization.authorize() }
        )

        #expect(result.errorCode == "AUTOMATION_OWNER_CONFLICT")
        #expect(await authorization.checkCount == 1)
        #expect(await broker.readCount == 0)
        #expect(await provider.loginCount == 0)
    }

    @Test("generation change cancels prior work, blocks stale completion, and global mutex rejects overlap")
    func generationCancellationAndMutex() async {
        let provider = CoordinatorStubProvider(.dorm, holdSession: true)
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(providers: [provider], credentialBroker: broker)
        let first = Task {
            await coordinator.login(context: context(dorm: true), username: "synthetic")
        }
        await provider.waitUntilSessionStarted()

        let overlap = await coordinator.login(context: context(dorm: true), username: "synthetic")
        #expect(overlap.errorCode == "OPERATION_IN_PROGRESS")
        await coordinator.networkChanged(to: 1)
        let cancelled = await first.value
        let stale = await coordinator.login(context: context(generation: 0, dorm: true), username: "synthetic")

        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.errorCode == "ENV_NETWORK_CHANGED")
        #expect(stale.errorCode == "ENV_NETWORK_CHANGED")
        #expect(await broker.readCount == 0)
        #expect(await provider.loginCount == 0)
        #expect(await provider.cancelledGenerations == [0])
    }

    @Test("held login prevents concurrent logout globally")
    func loginLogoutMutualExclusion() async {
        let provider = CoordinatorStubProvider(.dorm, holdSession: true)
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(providers: [provider], credentialBroker: broker)
        let login = Task {
            await coordinator.login(context: context(dorm: true), username: "synthetic")
        }
        await provider.waitUntilSessionStarted()

        let logout = await coordinator.logout(
            context: context(dorm: true),
            username: "synthetic",
            providerID: .dorm
        )
        #expect(logout.errorCode == "OPERATION_IN_PROGRESS")
        #expect(await provider.logoutCount == 0)

        await coordinator.networkChanged(to: 1)
        _ = await login.value
    }

    @Test("provider backoff is independent, follows 2/5/10/15 minutes, and clamps jitter to 15 percent")
    func providerBackoffSchedule() async {
        let retryFailure = ProviderAuthResult(
            outcome: .failed,
            providerID: .dorm,
            errorCode: "NET_TIMEOUT",
            retryable: true
        )
        let dorm = CoordinatorStubProvider(.dorm, loginResult: retryFailure)
        let teaching = CoordinatorStubProvider(.teaching)
        let broker = CoordinatorCredentialBroker()
        let clock = CoordinatorTestClock(Date(timeIntervalSince1970: 1_000))
        let coordinator = CampusNetworkCoordinator(
            providers: [dorm, teaching],
            credentialBroker: broker,
            settings: .init(dormEnabled: true, teachingEnabled: true),
            clock: { clock.now },
            jitterFraction: { 0.50 }
        )
        let expected: [TimeInterval] = [120, 300, 600, 900].map { $0 * 1.15 }

        for delay in expected {
            let before = clock.now
            let result = await coordinator.login(context: context(dorm: true), username: "synthetic")
            #expect(result.errorCode == "NET_TIMEOUT")
            guard case .backingOff(.dorm, let until) = await coordinator.state else {
                Issue.record("missing dorm backoff state")
                return
            }
            #expect(abs(until.timeIntervalSince(before) - delay) < 0.001)

            let blocked = await coordinator.login(context: context(dorm: true), username: "synthetic")
            #expect(blocked.errorCode == "PROVIDER_BACKING_OFF")
            clock.set(until.addingTimeInterval(1))
        }

        let teachingResult = await coordinator.login(
            context: context(teaching: true),
            username: "synthetic"
        )
        #expect(teachingResult.outcome == .succeeded)
        #expect(await teaching.loginCount == 1)
    }

    @Test("fatal provider state survives network generation changes")
    func fatalPersistsAcrossGeneration() async {
        let provider = CoordinatorStubProvider(
            .dorm,
            loginResult: ProviderAuthResult(
                outcome: .failed,
                providerID: .dorm,
                errorCode: "AUTH_BAD_PASSWORD"
            )
        )
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(providers: [provider], credentialBroker: broker)

        let first = await coordinator.login(context: context(dorm: true), username: "synthetic")
        await coordinator.networkChanged(to: 1)
        let second = await coordinator.login(
            context: context(generation: 1, dorm: true),
            username: "synthetic"
        )

        #expect(first.errorCode == "AUTH_BAD_PASSWORD")
        #expect(second.errorCode == "AUTH_BAD_PASSWORD")
        #expect(await broker.readCount == 1)
        #expect(await provider.loginCount == 1)
    }

    private func runSingle(
        providerID: CampusProviderID,
        settings: CampusCoordinatorSettings,
        context: CampusNetworkContext
    ) async -> (result: ProviderAuthResult, credentialReads: Int, loginCalls: Int) {
        let provider = CoordinatorStubProvider(providerID)
        let broker = CoordinatorCredentialBroker()
        let coordinator = CampusNetworkCoordinator(
            providers: [provider],
            credentialBroker: broker,
            settings: settings
        )
        let result = await coordinator.login(context: context, username: "synthetic")
        return (result, await broker.readCount, await provider.loginCount)
    }

    private func context(
        generation: UInt64 = 0,
        dorm: Bool = false,
        teaching: Bool = false
    ) -> CampusNetworkContext {
        CampusNetworkContext(
            generation: generation,
            sourceInterface: "fixture0",
            sourceIP: "198.51.100.27",
            sourceRouteBound: true,
            dormPortalIdentityVerified: dorm,
            teachingPortalIdentityVerified: teaching
        )
    }
}

private actor CoordinatorCredentialBroker: CampusCredentialBroker {
    private(set) var readCount = 0

    func openCredential(for providerID: CampusProviderID, username: String) async throws -> CredentialHandle? {
        readCount += 1
        return CredentialHandle("synthetic-only")
    }
}

private actor CoordinatorCredentialAuthorization {
    private(set) var checkCount = 0
    private let allowed: Bool

    init(allowed: Bool) { self.allowed = allowed }

    func authorize() -> Bool {
        checkCount += 1
        return allowed
    }
}

private actor CoordinatorStubProvider: NetworkAuthProvider {
    nonisolated let providerID: CampusProviderID
    private let session: ProviderSessionState
    private let loginResult: ProviderAuthResult
    private let holdSession: Bool
    private let onlineDeviceCount: Int?
    private let onlineDeviceLimit: Int?
    private var sessionStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var loginCount = 0
    private(set) var logoutCount = 0
    private(set) var cancelledGenerations: [UInt64] = []

    init(
        _ providerID: CampusProviderID,
        session: ProviderSessionState = .offline,
        loginResult: ProviderAuthResult? = nil,
        holdSession: Bool = false,
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil
    ) {
        self.providerID = providerID
        self.session = session
        self.loginResult = loginResult ?? ProviderAuthResult(
            outcome: .succeeded,
            providerID: providerID,
            sessionState: .online,
            accountMatch: .matches,
            clientIP: "198.51.100.27"
        )
        self.holdSession = holdSession
        self.onlineDeviceCount = onlineDeviceCount
        self.onlineDeviceLimit = onlineDeviceLimit
    }

    func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe {
        let visible = providerID == .dorm
            ? context.dormPortalIdentityVerified
            : context.teachingPortalIdentityVerified
        guard visible else {
            return ProviderProbe(providerID: providerID, support: .unsupported)
        }
        return ProviderProbe(
            providerID: providerID,
            support: .supported,
            confidence: .verified,
            sourceIP: context.sourceIP,
            clientIP: context.sourceIP
        )
    }

    func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult {
        sessionStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdSession {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return ProviderSessionResult(
            state: session,
            accountMatch: session == .online ? .matches : .unknown,
            clientIP: probe.clientIP,
            onlineDeviceCount: onlineDeviceCount,
            onlineDeviceLimit: onlineDeviceLimit,
            errorCode: session == .unknown ? "SESSION_UNKNOWN" : nil
        )
    }

    func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult {
        loginCount += 1
        return loginResult
    }

    func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        logoutCount += 1
        return ProviderAuthResult(
            outcome: .succeeded,
            providerID: providerID,
            sessionState: .offline
        )
    }

    func cancelPendingOperations(generation: UInt64) async {
        cancelledGenerations.append(generation)
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitUntilSessionStarted() async {
        guard !sessionStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor RecoveryProviderStub: NetworkAuthProvider {
    nonisolated let providerID = CampusProviderID.dorm
    private var sessions: [ProviderSessionResult]
    private(set) var loginCount = 0

    init(sessions: [ProviderSessionResult]) {
        self.sessions = sessions
    }

    func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe {
        ProviderProbe(
            providerID: .dorm,
            support: context.dormPortalIdentityVerified ? .supported : .unsupported,
            confidence: context.dormPortalIdentityVerified ? .verified : .unknown,
            sourceIP: context.sourceIP,
            clientIP: context.sourceIP
        )
    }

    func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult {
        guard !sessions.isEmpty else {
            return ProviderSessionResult(state: .unknown, errorCode: "SESSION_UNKNOWN")
        }
        return sessions.removeFirst()
    }

    func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult {
        loginCount += 1
        return ProviderAuthResult(
            outcome: .succeeded,
            providerID: .dorm,
            sessionState: .online,
            accountMatch: .matches,
            onlineDeviceCount: 2,
            onlineDeviceLimit: 3
        )
    }

    func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        .blocked(.dorm, "INTERNAL_ERROR")
    }

    func cancelPendingOperations(generation: UInt64) async {}
}

private final class CoordinatorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
