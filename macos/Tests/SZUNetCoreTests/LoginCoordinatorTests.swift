import Foundation
import Testing
@testable import SZUNetCore

@Suite("Login coordinator", .serialized)
struct LoginCoordinatorTests {
    @Test("auto-login sends credentials only after the portal confirms offline")
    func autoLoginRequiresConfirmedOffline() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.checkAndLogin()
        let requests = await fixture.client.loginRequests

        #expect(result.outcome == .authenticated)
        #expect(requests.count == 1)
        #expect(requests.first?.username == "student")
        #expect(requests.first?.password == "test-secret")
        #expect(requests.first?.sourceIP == fixture.sourceIP)
    }

    @Test("legacy manual and automatic login stop at Dorm 3/3 without credentials")
    func deviceLimitStopsLegacyLogin() async throws {
        let automaticFixture = try CoordinatorFixture(
            sessionOnline: false,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )
        defer { automaticFixture.removeTemporaryFiles() }
        let automatic = await automaticFixture.coordinator.checkAndLogin()
        #expect(automatic.reason == "AUTH_DEVICE_LIMIT")
        #expect(automaticFixture.credentialStore.passwordReadCount == 0)
        #expect(await automaticFixture.client.loginRequests.isEmpty)

        let manualFixture = try CoordinatorFixture(
            sessionOnline: false,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )
        defer { manualFixture.removeTemporaryFiles() }
        let manual = await manualFixture.coordinator.loginNow()
        #expect(manual.reason == "AUTH_DEVICE_LIMIT")
        #expect(manualFixture.credentialStore.passwordReadCount == 0)
        #expect(await manualFixture.client.loginRequests.isEmpty)
    }

    @Test("legacy force login requires 3/3 and then performs one login")
    func forceLoginRequiresDeviceLimit() async throws {
        let fixture = try CoordinatorFixture(
            sessionOnline: false,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.forceLoginNow()
        #expect(result.outcome == .authenticated)
        #expect(fixture.credentialStore.passwordReadCount == 1)
        #expect(await fixture.client.loginRequests.count == 1)
    }

    @Test("status probes skip external URLs until the campus session is online")
    func offlineStatusProbeSkipsExternalInternet() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false)
        defer { fixture.removeTemporaryFiles() }

        let (_, status, _) = try await fixture.coordinator.probe()

        #expect(status.campusSessionState == .offline)
        #expect(status.internetReason == "skipped_session_offline")
        #expect(fixture.networkProbe.internetProbeCalls == 0)
    }

    @Test("status probes check external reachability only for a verified online session")
    func onlineStatusProbeChecksExternalInternet() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: true)
        defer { fixture.removeTemporaryFiles() }

        let (_, status, _) = try await fixture.coordinator.probe()

        #expect(status.campusSessionState == .online)
        #expect(status.campusInternetOK)
        #expect(fixture.networkProbe.internetProbeCalls == 1)
    }

    @Test("auto-login skips an already-online session")
    func autoLoginSkipsOnlineSession() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: true)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.checkAndLogin()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "session_already_online")
        #expect(await fixture.client.loginRequests.isEmpty)
        #expect(fixture.credentialStore.passwordReadCount == 0)
    }

    @Test("auto-login fails closed when session state is unknown")
    func autoLoginSkipsUnknownSession() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: nil)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.checkAndLogin()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "session_unverified")
        #expect(await fixture.client.loginRequests.isEmpty)
        #expect(fixture.credentialStore.passwordReadCount == 0)
    }

    @Test("pausing while a session check is running prevents the final credential send")
    func pauseBeforeFinalSendSkipsLogin() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false, holdSessionCheck: true)
        defer { fixture.removeTemporaryFiles() }

        let task = Task { await fixture.coordinator.checkAndLogin() }
        await fixture.client.waitUntilSessionCheckStarts()
        try fixture.pauseStore.pause()
        await fixture.client.releaseSessionCheck()
        let result = await task.value

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "paused")
        #expect(await fixture.client.loginRequests.isEmpty)
    }

    @Test("task cancellation prevents auto-login")
    func cancellationPreventsLogin() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false, holdSessionCheck: true)
        defer { fixture.removeTemporaryFiles() }

        let task = Task { await fixture.coordinator.checkAndLogin() }
        await fixture.client.waitUntilSessionCheckStarts()
        task.cancel()
        await fixture.client.releaseSessionCheck()
        let result = await task.value

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "cancelled")
        #expect(await fixture.client.loginRequests.isEmpty)
    }

    @Test("manual login remains available while paused after verified offline gating")
    func manualLoginWorksWhilePausedAfterVerifiedOffline() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false)
        defer { fixture.removeTemporaryFiles() }
        try fixture.pauseStore.pause()

        let result = await fixture.coordinator.loginNow()
        let requests = await fixture.client.loginRequests

        #expect(result.outcome == .authenticated)
        #expect(fixture.pauseStore.isPaused)
        #expect(requests.count == 1)
        #expect(requests.first?.sourceIP == fixture.sourceIP)
        #expect(fixture.credentialStore.passwordReadCount == 1)
    }

    @Test("manual login reads no credential when session state is unknown")
    func manualLoginSkipsUnknownSessionWithoutCredentialRead() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: nil)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.loginNow()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "session_unverified")
        #expect(await fixture.client.loginRequests.isEmpty)
        #expect(fixture.credentialStore.passwordReadCount == 0)
    }

    @Test("manual login reads no credential on a non-campus route")
    func manualLoginSkipsNonCampusWithoutCredentialRead() async throws {
        let fixture = try CoordinatorFixture(
            sessionOnline: false,
            sourceIP: "192.0.2.44",
            autoLoginAvailable: false
        )
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.loginNow()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "unverified_source_ip")
        #expect(await fixture.client.loginRequests.isEmpty)
        #expect(fixture.credentialStore.passwordReadCount == 0)
    }

    @Test("manual logout pauses auto-login before mapping verified success")
    func logoutPausesAndMapsVerifiedSuccess() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: true)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.logout()
        let requests = await fixture.client.logoutRequests

        #expect(result.outcome == .loggedOut)
        #expect(result.reason == "logout_confirmed")
        #expect(fixture.pauseStore.isPaused)
        #expect(requests.count == 1)
        #expect(requests.first?.sourceIP == fixture.sourceIP)
    }

    @Test("a cross-process authentication lease blocks concurrent portal actions")
    func crossProcessLeasePreventsConcurrentAuthentication() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: false)
        defer { fixture.removeTemporaryFiles() }
        let holder = try ExternalFileLockHolder(lockURL: fixture.paths.authenticationLockFile)
        defer { holder.stop() }

        let result = await fixture.coordinator.loginNow()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "operation_in_progress")
        #expect(await fixture.client.loginRequests.isEmpty)
    }
}

private struct PortalRequest: Sendable {
    var username: String
    var password: String
    var sourceIP: String
}

private struct PortalLogoutRequest: Sendable {
    var username: String
    var sourceIP: String
}

private actor StubDrCOMService: DrCOMServicing {
    private let sessionOnline: Bool?
    private let onlineDeviceCount: Int?
    private let onlineDeviceLimit: Int?
    private let holdSessionCheck: Bool
    private var sessionCheckStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    private(set) var loginRequests: [PortalRequest] = []
    private(set) var logoutRequests: [PortalLogoutRequest] = []

    init(
        sessionOnline: Bool?,
        holdSessionCheck: Bool,
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil
    ) {
        self.sessionOnline = sessionOnline
        self.holdSessionCheck = holdSessionCheck
        self.onlineDeviceCount = onlineDeviceCount
        self.onlineDeviceLimit = onlineDeviceLimit
    }

    func login(username: String, password: String, knownSourceIP: String) async -> LoginResult {
        loginRequests.append(
            PortalRequest(username: username, password: password, sourceIP: knownSourceIP)
        )
        return LoginResult(status: .success, reason: "session_verified", sourceIP: knownSourceIP)
    }

    func logout(username: String, knownSourceIP: String) async -> LogoutResult {
        logoutRequests.append(PortalLogoutRequest(username: username, sourceIP: knownSourceIP))
        return LogoutResult(status: .success, reason: "portal_logout_verified")
    }

    func isSessionOnline(username: String, sourceIP: String) async -> Bool? {
        sessionCheckStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if holdSessionCheck {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return sessionOnline
    }

    func sessionStatus(username: String, sourceIP: String) async -> ProviderSessionResult {
        let online = await isSessionOnline(username: username, sourceIP: sourceIP)
        let state: ProviderSessionState = switch online {
        case .some(true): .online
        case .some(false): .offline
        case .none: .unknown
        }
        return ProviderSessionResult(
            state: state,
            accountMatch: state == .online ? .matches : .unknown,
            clientIP: sourceIP,
            onlineDeviceCount: onlineDeviceCount,
            onlineDeviceLimit: onlineDeviceLimit,
            errorCode: state == .unknown ? "SESSION_UNKNOWN" : nil
        )
    }

    func waitUntilSessionCheckStarts() async {
        guard !sessionCheckStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSessionCheck() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class StubCredentialStore: CredentialStoring {
    private let storedPassword: String?
    private(set) var passwordReadCount = 0

    init(password: String?) {
        storedPassword = password
    }

    func password(service: String, account: String) throws -> String? {
        passwordReadCount += 1
        return storedPassword
    }

    func setPassword(_ password: String, service: String, account: String) throws {}
    func deletePassword(service: String, account: String) throws {}
}

private final class StubNetworkProbe: NetworkProbing {
    let status: NetworkStatus
    let environment: NetworkEnvironment
    private(set) var internetProbeCalls = 0

    init(sourceIP: String, autoLoginAvailable: Bool = true) {
        status = NetworkStatus(
            gatewayReachable: true,
            campusInternetOK: false,
            gatewayHost: "172.30.255.42",
            sourceIP: sourceIP,
            gatewayReason: "connected",
            internetReason: "portal_redirect",
            internetPortalRedirect: true
        )
        environment = NetworkEnvironment(
            label: autoLoginAvailable ? "宿舍网络" : "未验证网络",
            isDormNetwork: autoLoginAvailable,
            autoLoginAvailable: autoLoginAvailable,
            sourceIP: sourceIP,
            reason: "source_ip_verified"
        )
    }

    func probeGateway(configuration: AppConfiguration) -> NetworkStatus { status }

    func probeInternet(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) async -> NetworkStatus {
        internetProbeCalls += 1
        var result = status
        result.campusInternetOK = true
        result.internetReason = "ok"
        return result
    }

    func classify(configuration: AppConfiguration, status: NetworkStatus) -> NetworkEnvironment {
        environment
    }
}

private struct CoordinatorFixture {
    let root: URL
    let paths: AppPaths
    let pauseStore: PauseStore
    let client: StubDrCOMService
    let credentialStore: StubCredentialStore
    let networkProbe: StubNetworkProbe
    let coordinator: LoginCoordinator
    let sourceIP: String

    init(
        sessionOnline: Bool?,
        holdSessionCheck: Bool = false,
        sourceIP: String = "172.24.59.154",
        autoLoginAvailable: Bool = true,
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil
    ) throws {
        self.sourceIP = sourceIP
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            logDirectory: root.appendingPathComponent("Logs", isDirectory: true)
        )
        let configurationStore = ConfigurationStore(paths: paths, legacyCandidates: [])
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        try configurationStore.save(configuration)

        pauseStore = PauseStore(
            fileURL: paths.pauseFile,
            lockFileURL: paths.pauseLockFile,
            legacyFileURL: nil,
            migrationFileURL: paths.legacyPauseMigrationFile
        )
        let stubClient = StubDrCOMService(
            sessionOnline: sessionOnline,
            holdSessionCheck: holdSessionCheck,
            onlineDeviceCount: onlineDeviceCount,
            onlineDeviceLimit: onlineDeviceLimit
        )
        client = stubClient
        let stubCredentialStore = StubCredentialStore(password: "test-secret")
        credentialStore = stubCredentialStore
        let stubNetworkProbe = StubNetworkProbe(
            sourceIP: sourceIP,
            autoLoginAvailable: autoLoginAvailable
        )
        networkProbe = stubNetworkProbe
        coordinator = LoginCoordinator(
            configurationStore: configurationStore,
            credentials: stubCredentialStore,
            pauseStore: pauseStore,
            networkProbe: stubNetworkProbe,
            logger: AppLogger(fileURL: paths.logFile),
            clientFactory: { _ in stubClient }
        )
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}
