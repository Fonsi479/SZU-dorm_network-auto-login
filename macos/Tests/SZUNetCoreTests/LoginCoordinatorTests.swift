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
    }

    @Test("auto-login fails closed when session state is unknown")
    func autoLoginSkipsUnknownSession() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: nil)
        defer { fixture.removeTemporaryFiles() }

        let result = await fixture.coordinator.checkAndLogin()

        #expect(result.outcome == .unchanged)
        #expect(result.reason == "session_unverified")
        #expect(await fixture.client.loginRequests.isEmpty)
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

    @Test("manual login remains available while auto-login is paused")
    func manualLoginWorksWhilePaused() async throws {
        let fixture = try CoordinatorFixture(sessionOnline: nil)
        defer { fixture.removeTemporaryFiles() }
        try fixture.pauseStore.pause()

        let result = await fixture.coordinator.loginNow()
        let requests = await fixture.client.loginRequests

        #expect(result.outcome == .authenticated)
        #expect(fixture.pauseStore.isPaused)
        #expect(requests.count == 1)
        #expect(requests.first?.sourceIP.isEmpty == true)
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
    private let holdSessionCheck: Bool
    private var sessionCheckStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    private(set) var loginRequests: [PortalRequest] = []
    private(set) var logoutRequests: [PortalLogoutRequest] = []

    init(sessionOnline: Bool?, holdSessionCheck: Bool) {
        self.sessionOnline = sessionOnline
        self.holdSessionCheck = holdSessionCheck
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

    init(password: String?) {
        storedPassword = password
    }

    func password(service: String, account: String) throws -> String? {
        storedPassword
    }

    func setPassword(_ password: String, service: String, account: String) throws {}
    func deletePassword(service: String, account: String) throws {}
}

private final class StubNetworkProbe: NetworkProbing {
    let status: NetworkStatus
    let environment: NetworkEnvironment
    private(set) var internetProbeCalls = 0

    init(sourceIP: String) {
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
            label: "宿舍网络",
            isDormNetwork: true,
            autoLoginAvailable: true,
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
    let networkProbe: StubNetworkProbe
    let coordinator: LoginCoordinator
    let sourceIP = "172.24.59.154"

    init(sessionOnline: Bool?, holdSessionCheck: Bool = false) throws {
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
            holdSessionCheck: holdSessionCheck
        )
        client = stubClient
        let stubNetworkProbe = StubNetworkProbe(sourceIP: sourceIP)
        networkProbe = stubNetworkProbe
        coordinator = LoginCoordinator(
            configurationStore: configurationStore,
            credentials: StubCredentialStore(password: "test-secret"),
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
