import Foundation
import Testing
@testable import SZUNETEmbedded
import SZUNETFeature
import SZUNetCore

@Suite("SZUNET embedded runtime")
struct SZUNETEmbeddedRuntimeTests {
    @Test("an already-online login result is shown as connected instead of an error")
    @MainActor
    func alreadyOnlineIsPositivePresentation() {
        let model = SZUNETManagementModel(
            runtime: makeRuntime(controller: FakeController(), store: FakeStateStore())
        )
        model.result = SZUNETCommandResult(
            requestId: "already-online",
            outcome: .unchanged,
            provider: .dorm,
            networkContext: .dorm,
            sessionState: .online,
            errorCode: "SESSION_ONLINE",
            automaticEnabled: true,
            observedAt: Date()
        )

        #expect(model.currentStatusTitle == "校园网已连接")
        #expect(model.currentStatusDetail == "当前会话已通过 Provider 验证，可以正常使用。")
        #expect(model.technicalCode == nil)
        #expect(model.statusTone == .positive)
    }

    @Test("embedded commands honor their public timeout")
    func embeddedCommandTimeoutIsBounded() async throws {
        let runtime = makeRuntime(controller: SlowLogoutController(), store: FakeStateStore())
        try await runtime.start(enabled: true)

        let result = try await runtime.execute(
            .logout,
            provider: .dorm,
            interactive: true,
            timeoutSeconds: 1
        )

        #expect(result.errorCode == "ADAPTER_TIMEOUT")
        #expect(result.outcome == .blocked)
        try await runtime.shutdown()
    }

    @Test("existing standalone configuration becomes legacy owner before Core can create files")
    func existingConfigurationPreservesStandaloneOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-embedded-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(applicationSupportDirectory: root, logDirectory: root.appendingPathComponent("logs"))
        try Data("{}".utf8).write(to: paths.campusProviderConfigurationFile)

        let owner = SZUNETEmbeddedRuntime.legacyOwnerIfNeeded(paths: paths)

        #expect(owner?.hostID == "com.szu-netlogin.dorm-login")
        #expect(owner?.supportsOwnershipProtocol == false)
        #expect(!FileManager.default.fileExists(atPath: paths.automationFile.path))
    }

    @Test("disabled runtime performs no Core or shared-store work")
    func disabledHasNoSideEffects() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)

        let result = try await runtime.execute(.status, provider: .auto, interactive: false, timeoutSeconds: 10)

        #expect(result.errorCode == "PROVIDER_DISABLED")
        #expect(await controller.operationCount == 0)
        #expect(await store.operationCount == 0)
    }

    @Test("network event automatically logs in only after current ownership is reverified")
    func automaticLoginOwnerGate() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)

        try await runtime.start(enabled: true)
        await runtime.networkDidChange()

        #expect(await controller.networkChangeCount == 1)
        #expect(await controller.automaticLoginCount == 1)
        #expect(await controller.automaticRecoveryCount == 1)
        #expect(await store.verifyCount == 1)
        #expect(try await runtime.ownershipSnapshot().isCurrentHostOwner)
        try await runtime.shutdown()
    }

    @Test("automatic recovery writes only redacted trigger and aggregate evidence")
    func automaticRecoveryLoggingIsSanitized() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-recovery-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("recovery.log")
        let controller = FakeController()
        await controller.setAutomaticRecoveryResult(
            ProviderAuthResult(
                outcome: .blocked,
                providerID: .dorm,
                sessionState: .online,
                accountMatch: .matches,
                clientIP: "198.51.100.27",
                onlineDeviceCount: 2,
                onlineDeviceLimit: 3,
                errorCode: "NET_CAMPUS_EGRESS_UNAVAILABLE"
            )
        )
        let runtime = makeRuntime(
            controller: controller,
            store: FakeStateStore(),
            logger: AppLogger(fileURL: logURL)
        )

        try await runtime.start(enabled: true)
        await runtime.networkDidChange()
        let text = try String(contentsOf: logURL, encoding: .utf8)

        #expect(text.contains("trigger=network-change"))
        #expect(text.contains("session=online"))
        #expect(text.contains("devices=2/3"))
        #expect(text.contains("result=NET_CAMPUS_EGRESS_UNAVAILABLE"))
        #expect(!text.contains("198.51.100.27"))
        #expect(!text.lowercased().contains("url="))
        #expect(!text.lowercased().contains("response"))
        #expect(!text.lowercased().contains("password"))
        try await runtime.shutdown()
    }

    @Test("host-managed scheduling leaves fallback automation to the shell")
    func hostManagedSchedulingDoesNotAutoLogin() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(
            controller: controller,
            store: store,
            managesFallbackScheduling: false
        )

        try await runtime.start(enabled: true)
        await runtime.networkDidChange()

        #expect(await controller.networkChangeCount == 1)
        #expect(await controller.automaticLoginCount == 0)
        #expect(await store.verifyCount == 0)
        try await runtime.shutdown()
    }

    @Test("force-login routes only explicit interactive Dorm commands")
    func forceLoginCommandRouting() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)
        try await runtime.start(enabled: true)

        let result = try await runtime.execute(
            .forceLogin,
            provider: .dorm,
            interactive: true,
            timeoutSeconds: 5
        )
        #expect(result.outcome == .succeeded)
        #expect(await controller.events.contains("forceLogin:dorm"))

        let before = await controller.forceLoginCount
        let nonInteractive = try await runtime.execute(
            .forceLogin,
            provider: .dorm,
            interactive: false,
            timeoutSeconds: 5
        )
        #expect(nonInteractive.errorCode == "AUTH_NOT_CONFIRMED")
        #expect(await controller.forceLoginCount == before)

        let teaching = try await runtime.execute(
            .forceLogin,
            provider: .teaching,
            interactive: true,
            timeoutSeconds: 5
        )
        #expect(teaching.errorCode == "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED")
        #expect(await controller.forceLoginCount == before)
        try await runtime.shutdown()
    }

    @Test("shutdown retains owner while explicit disable releases it")
    func lifecycleOwnershipSemantics() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)

        try await runtime.start(enabled: true)
        try await runtime.shutdown()
        #expect(await store.owner?.host.hostID == "mac-manager")
        #expect(await store.owner?.running == false)

        try await runtime.start(enabled: true)
        try await runtime.disableAndReleaseOwnership()
        #expect(await store.owner == nil)
    }

    @Test("legacy owner capability is refreshed before ownership transfer")
    func legacyCapabilityRefresh() async throws {
        let legacy = CampusAutomationHost(
            hostID: "standalone",
            displayName: "SZU Dorm Login",
            bundleID: "com.szu-netlogin.dorm-login",
            supportsOwnershipProtocol: false
        )
        let store = FakeStateStore(owner: CampusAutomationOwner(host: legacy, running: true))
        let runtime = makeRuntime(
            controller: FakeController(),
            store: store,
            checker: FakeCapabilityChecker(supported: true)
        )
        try await runtime.start(enabled: true)

        let snapshot = try await runtime.takeAutomationOwnership()

        #expect(snapshot.isCurrentHostOwner)
        #expect(await store.capabilityRefreshCount == 1)
        #expect(await store.owner?.host.hostID == "mac-manager")
        try await runtime.disableAndReleaseOwnership()
    }

    @Test("unknown legacy capability refuses ownership transfer")
    func legacyCapabilityRefusal() async throws {
        let legacy = CampusAutomationHost(
            hostID: "standalone",
            displayName: "旧版 SZU Dorm Login",
            bundleID: "com.szu-netlogin.dorm-login",
            supportsOwnershipProtocol: false
        )
        let store = FakeStateStore(owner: CampusAutomationOwner(host: legacy, running: true))
        let runtime = makeRuntime(
            controller: FakeController(),
            store: store,
            checker: FakeCapabilityChecker(supported: false)
        )
        try await runtime.start(enabled: true)

        await #expect(throws: CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(
            legacy.displayName
        )) {
            try await runtime.takeAutomationOwnership()
        }
        #expect(await store.owner?.host.hostID == legacy.hostID)
        #expect(await store.capabilityRefreshCount == 1)
        try await runtime.shutdown()
    }

    @Test("management model routes every visible control through the in-process runtime")
    @MainActor
    func managementControlsUseRuntime() async throws {
        let controller = FakeController()
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)
        try await runtime.start(enabled: true)
        let model = SZUNETManagementModel(runtime: runtime)

        await model.load()
        model.run(.login, provider: .teaching)
        await waitUntilIdle(model)
        model.run(.logout, provider: .dorm)
        await waitUntilIdle(model)
        model.run(.check)
        await waitUntilIdle(model)
        model.run(.pause)
        await waitUntilIdle(model)
        model.run(.resume)
        await waitUntilIdle(model)
        model.run(.disableProbe)
        await waitUntilIdle(model)
        model.run(.enableProbe)
        await waitUntilIdle(model)
        model.setProbeInterval(.twoMinutes)
        await waitUntilIdle(model)
        model.run(.diagnostics)
        await waitUntilIdle(model)

        model.dormAccount = "fixture-account"
        model.dormPassword = "fixture-password"
        await model.saveProviders()
        await model.releaseOwnership()

        let events = await controller.events
        #expect(events.contains("login:teaching:manual"))
        #expect(events.contains("logout:dorm"))
        #expect(events.contains("pause"))
        #expect(events.contains("resume"))
        #expect(events.filter { $0 == "refresh" }.count >= 3)
        #expect(await store.automation.networkProbeEnabled)
        #expect(await store.automation.probeIntervalSeconds == 120)
        #expect(await store.savedPasswordProviders == [.dorm])
        #expect(await store.owner == nil)
    }

    @Test("device-limit confirmation is opt-in and dispatches force once")
    @MainActor
    func managementDeviceLimitConfirmation() async throws {
        let controller = FakeController()
        await controller.setManualLoginResult(
            ProviderAuthResult(
                outcome: .blocked,
                providerID: .dorm,
                sessionState: .offline,
                onlineDeviceCount: 3,
                onlineDeviceLimit: 3,
                errorCode: "AUTH_DEVICE_LIMIT"
            )
        )
        let store = FakeStateStore()
        let runtime = makeRuntime(controller: controller, store: store)
        try await runtime.start(enabled: true)
        let model = SZUNETManagementModel(runtime: runtime)

        model.run(.login, provider: .dorm)
        await waitUntilIdle(model)
        #expect(model.forceLoginProvider == .dorm)
        #expect(await controller.forceLoginCount == 0)

        model.cancelForceLogin()
        #expect(model.forceLoginProvider == nil)
        #expect(await controller.forceLoginCount == 0)

        await controller.setManualLoginResult(
            ProviderAuthResult(
                outcome: .blocked,
                providerID: .dorm,
                sessionState: .offline,
                onlineDeviceCount: 3,
                onlineDeviceLimit: 3,
                errorCode: "AUTH_DEVICE_LIMIT"
            )
        )
        model.run(.login, provider: .dorm)
        await waitUntilIdle(model)
        model.confirmForceLogin()
        await waitUntilIdle(model)
        #expect(await controller.forceLoginCount == 1)
        model.confirmForceLogin()
        #expect(await controller.forceLoginCount == 1)
        try await runtime.shutdown()
    }

    @Test("offline visual fixture shows 3/3 and the force-switch confirmation")
    @MainActor
    func visualReferenceShowsDeviceLimitConfirmation() {
        let model = SZUNETManagementModel.visualReference()
        #expect(model.result?.sessionState == .offline)
        #expect(model.result?.onlineDeviceCount == 3)
        #expect(model.result?.onlineDeviceLimit == 3)
        #expect(model.onlineDeviceText == "3/3")
        #expect(model.forceLoginProvider == .dorm)
    }
}

@MainActor
private func waitUntilIdle(_ model: SZUNETManagementModel) async {
    for _ in 0 ..< 100 {
        if !model.isWorking { return }
        await Task.yield()
    }
    Issue.record("management model did not become idle")
}

private func makeRuntime(
    controller: any SZUNETEmbeddedControlling,
    store: FakeStateStore,
    checker: any SZUNETHostCapabilityChecking = FakeCapabilityChecker(supported: false),
    managesFallbackScheduling: Bool = true,
    logger: AppLogger = AppLogger(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-embedded-test-\(UUID().uuidString).log")
    )
) -> SZUNETEmbeddedRuntime {
    SZUNETEmbeddedRuntime(
        configuration: SZUNETEmbeddedConfiguration(
            hostID: "mac-manager",
            displayName: "我的 Mac 管家",
            bundleIdentifier: "com.example.mac-manager",
            sharedDirectory: URL(fileURLWithPath: "/tmp/szunet-embedded-tests"),
            managesFallbackScheduling: managesFallbackScheduling
        ),
        controller: controller,
        stateStore: store,
        capabilityChecker: checker,
        logger: logger,
        requestID: { "request-id" }
    )
}

private actor SlowLogoutController: SZUNETEmbeddedControlling {
    func currentSnapshot() -> CampusProductSnapshot { Self.snapshot }
    func refresh() -> CampusProductSnapshot { Self.snapshot }
    func login(requestedProvider: CampusProviderID?, automatic: Bool) -> ProviderAuthResult {
        .blocked(requestedProvider ?? .dorm, "INTERNAL_ERROR")
    }
    func forceLogin(requestedProvider: CampusProviderID?) -> ProviderAuthResult {
        .blocked(requestedProvider ?? .dorm, "INTERNAL_ERROR")
    }
    func logout(providerID: CampusProviderID) async -> ProviderAuthResult {
        do {
            try await Task.sleep(for: .seconds(10))
            return ProviderAuthResult(
                outcome: .succeeded,
                providerID: providerID,
                sessionState: .offline
            )
        } catch {
            return ProviderAuthResult(
                outcome: .cancelled,
                providerID: providerID,
                errorCode: "OPERATION_CANCELLED"
            )
        }
    }
    func pause() {}
    func resume() {}
    func networkChanged() {}
    func updateConfiguration(_ configuration: CampusProductConfiguration) {}

    private static let snapshot = CampusProductSnapshot(
        generation: 0,
        category: .dorm,
        automaticEnabled: true,
        dorm: .init(enabled: true, accountLabel: "u***r", lifecycle: "online"),
        teaching: .init(enabled: false, accountLabel: "", lifecycle: "idle")
    )
}

private actor FakeController: SZUNETEmbeddedControlling {
    var operationCount = 0
    var networkChangeCount = 0
    var automaticLoginCount = 0
    var automaticRecoveryCount = 0
    var forceLoginCount = 0
    var events: [String] = []
    var manualLoginResult: ProviderAuthResult?
    var automaticRecoveryResult: ProviderAuthResult?
    var snapshot = CampusProductSnapshot(
        generation: 0,
        category: .dorm,
        automaticEnabled: true,
        dorm: .init(enabled: true, accountLabel: "u***r", lifecycle: "offline"),
        teaching: .init(enabled: false, accountLabel: "", lifecycle: "idle")
    )

    func currentSnapshot() -> CampusProductSnapshot { snapshot }
    func setManualLoginResult(_ result: ProviderAuthResult?) { manualLoginResult = result }
    func setAutomaticRecoveryResult(_ result: ProviderAuthResult?) { automaticRecoveryResult = result }
    func refresh() -> CampusProductSnapshot {
        operationCount += 1
        events.append("refresh")
        return snapshot
    }
    func login(requestedProvider: CampusProviderID?, automatic: Bool) -> ProviderAuthResult {
        operationCount += 1
        if automatic { automaticLoginCount += 1 }
        events.append("login:\((requestedProvider ?? .dorm).rawValue):\(automatic ? "automatic" : "manual")")
        if !automatic, let manualLoginResult {
            self.manualLoginResult = nil
            return manualLoginResult
        }
        return ProviderAuthResult(outcome: .succeeded, providerID: requestedProvider ?? .dorm, sessionState: .online)
    }
    func recoverAutomatically() -> ProviderAuthResult {
        automaticRecoveryCount += 1
        if let automaticRecoveryResult { return automaticRecoveryResult }
        return login(requestedProvider: nil, automatic: true)
    }
    func forceLogin(requestedProvider: CampusProviderID?) -> ProviderAuthResult {
        operationCount += 1
        forceLoginCount += 1
        events.append("forceLogin:\((requestedProvider ?? .dorm).rawValue)")
        return ProviderAuthResult(outcome: .succeeded, providerID: requestedProvider ?? .dorm, sessionState: .online)
    }
    func logout(providerID: CampusProviderID) -> ProviderAuthResult {
        operationCount += 1
        events.append("logout:\(providerID.rawValue)")
        return ProviderAuthResult(outcome: .succeeded, providerID: providerID, sessionState: .offline)
    }
    func pause() { operationCount += 1; events.append("pause") }
    func resume() { operationCount += 1; events.append("resume") }
    func networkChanged() { networkChangeCount += 1 }
    func updateConfiguration(_ configuration: CampusProductConfiguration) { operationCount += 1 }
}

private actor FakeStateStore: SZUNETEmbeddedStateStoring {
    var operationCount = 0
    var verifyCount = 0
    var capabilityRefreshCount = 0
    var owner: CampusAutomationOwner?
    var automation = CampusAutomationConfiguration()
    var providers = CampusProductConfiguration.default
    var savedPasswordProviders: [CampusProviderID] = []

    init(owner: CampusAutomationOwner? = nil) { self.owner = owner }

    func loadProviderConfiguration() -> CampusProductConfiguration { operationCount += 1; return providers }
    func savePassword(_ password: String, provider: CampusProviderID) {
        operationCount += 1
        savedPasswordProviders.append(provider)
    }
    func automationConfiguration() -> CampusAutomationConfiguration {
        operationCount += 1; automation.owner = owner; return automation
    }
    func ownership(for hostID: String) -> CampusAutomationOwnershipSnapshot {
        operationCount += 1; return snapshot(hostID)
    }
    func claimOwnership(for host: CampusAutomationHost) -> CampusAutomationOwnershipSnapshot {
        operationCount += 1
        if owner == nil { owner = CampusAutomationOwner(host: host, running: true) }
        return snapshot(host.hostID)
    }
    func transferOwnership(to host: CampusAutomationHost) throws -> CampusAutomationOwnershipSnapshot {
        operationCount += 1
        if let owner, !owner.host.supportsOwnershipProtocol {
            throw CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(owner.host.displayName)
        }
        owner = CampusAutomationOwner(host: host, running: true)
        return snapshot(host.hostID)
    }
    func releaseOwnership(from hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        operationCount += 1
        guard owner?.host.hostID == hostID else { throw CampusAutomationOwnershipError.callerIsNotOwner }
        owner = nil
        return snapshot(hostID)
    }
    func setOwnerRunning(_ running: Bool, hostID: String) throws -> CampusAutomationOwnershipSnapshot {
        operationCount += 1
        guard owner?.host.hostID == hostID else { throw CampusAutomationOwnershipError.callerIsNotOwner }
        owner?.running = running
        return snapshot(hostID)
    }
    func refreshOwnerCapability(
        hostID: String,
        supportsOwnershipProtocol: Bool
    ) throws -> CampusAutomationOwnershipSnapshot {
        operationCount += 1; capabilityRefreshCount += 1
        guard owner?.host.hostID == hostID else { throw CampusAutomationOwnershipError.callerIsNotOwner }
        owner?.host.supportsOwnershipProtocol = supportsOwnershipProtocol
        return snapshot(hostID)
    }
    func verifyOwnership(hostID: String) -> Bool {
        operationCount += 1; verifyCount += 1; return owner?.host.hostID == hostID
    }
    func setProbeEnabled(_ enabled: Bool) { operationCount += 1; automation.networkProbeEnabled = enabled }
    func setProbeInterval(_ seconds: Int) { operationCount += 1; automation.probeIntervalSeconds = seconds }

    private func snapshot(_ hostID: String) -> CampusAutomationOwnershipSnapshot {
        CampusAutomationOwnershipSnapshot(
            currentOwner: owner?.host,
            ownerRunning: owner?.running ?? false,
            canTransfer: owner == nil || owner?.host.hostID == hostID || owner?.host.supportsOwnershipProtocol == true,
            isCurrentHostOwner: owner?.host.hostID == hostID
        )
    }
}

private struct FakeCapabilityChecker: SZUNETHostCapabilityChecking {
    var supported: Bool
    func supportsOwnershipProtocol(bundleIdentifier: String) async -> Bool { supported }
}
