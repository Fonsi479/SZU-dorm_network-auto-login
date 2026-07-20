import Foundation
import Testing
@testable import SZUNETFeature

@Suite("SZUNET switch and cancellation boundary")
struct SZUNETBoundaryBehaviorTests {
    @Test("disabled module performs no probe or portal action")
    func disabledModuleIsStrongBoundary() async {
        let driver = BoundaryFakeDriver()
        let module = SZUNETModule(driverFactory: { driver })

        _ = await module.configure(featureEnabled: false, autoLoginEnabled: true)
        _ = await module.refresh()
        _ = await module.runAutomaticLoginIfDue(at: .distantFuture)
        _ = await module.manualLogin()
        _ = await module.manualLogout()

        #expect(await driver.currentCalls() == BoundaryFakeCalls())
        let snapshot = await module.currentSnapshot()
        #expect(!snapshot.status.featureEnabled)
        #expect(snapshot.detail.contains("不会探测"))
    }

    @Test("automatic login off preserves manual login")
    func childSwitchKeepsManualPath() async {
        let driver = BoundaryFakeDriver()
        let module = SZUNETModule(driverFactory: { driver })

        _ = await module.configure(featureEnabled: true, autoLoginEnabled: false)
        _ = await module.refresh()
        _ = await module.runAutomaticLoginIfDue(at: .distantFuture)
        let snapshot = await module.manualLogin()

        let calls = await driver.currentCalls()
        #expect(calls.manualLogin == 1)
        #expect(calls.automaticLogin == 0)
        #expect(snapshot.status.portal == .authenticated)
    }

    @Test("ineligible environment blocks automatic credential path")
    func automaticLoginRequiresEnvironmentGate() async {
        let driver = BoundaryFakeDriver(
            probeResult: SZUNETProbeResult(
                environment: .ineligible,
                portal: .unauthenticated,
                internet: .unreachable,
                environmentLabel: "非校园网",
                environmentReason: "source_ip_not_allowed",
                gatewayReason: "gateway_unreachable",
                internetReason: "skipped_session_offline",
                autoLoginPaused: false
            )
        )
        let module = SZUNETModule(driverFactory: { driver })

        _ = await module.configure(
            featureEnabled: true,
            autoLoginEnabled: true,
            resumeAutoLogin: true
        )
        _ = await module.refresh()
        _ = await module.runAutomaticLoginIfDue(at: .distantFuture)

        #expect(await driver.currentCalls().automaticLogin == 0)
    }

    @Test("manual logout suppression survives refresh")
    func manualLogoutSuppressionPersists() async {
        let driver = BoundaryFakeDriver()
        let module = SZUNETModule(driverFactory: { driver })

        _ = await module.configure(
            featureEnabled: true,
            autoLoginEnabled: true,
            resumeAutoLogin: true
        )
        _ = await module.refresh()
        _ = await module.manualLogout()
        let refreshed = await module.refresh()
        _ = await module.runAutomaticLoginIfDue(at: .distantFuture)

        let calls = await driver.currentCalls()
        #expect(calls.manualLogout == 1)
        #expect(calls.automaticLogin == 0)
        #expect(refreshed.manualLogoutSuppressed)
    }

    @Test("disabling the module cancels an active probe")
    func totalSwitchCancelsWork() async {
        let driver = BoundaryFakeDriver(probeDelay: .seconds(30))
        let module = SZUNETModule(driverFactory: { driver })
        _ = await module.configure(featureEnabled: true, autoLoginEnabled: false)

        let refreshTask = Task { await module.refresh() }
        while await driver.currentCalls().probe == 0 {
            await Task.yield()
        }
        let disabled = await module.configure(featureEnabled: false, autoLoginEnabled: false)
        _ = await refreshTask.value

        #expect(!disabled.status.featureEnabled)
        #expect(disabled.status.portal == .unknown)
        let calls = await driver.currentCalls()
        #expect(calls.probe == 1)
        #expect(calls.automaticLogin == 0)
    }
}

private struct BoundaryFakeCalls: Equatable, Sendable {
    var probe = 0
    var manualLogin = 0
    var automaticLogin = 0
    var manualLogout = 0
    var setAutoLogin = 0
    var configuration = 0
    var credentialWrites = 0
}

private actor BoundaryFakeDriver: SZUNETCoordinatorDriving {
    private var calls = BoundaryFakeCalls()
    private var probeResult: SZUNETProbeResult
    private let probeDelay: Duration?
    private var paused = false

    init(
        probeResult: SZUNETProbeResult = SZUNETProbeResult(
            environment: .eligible,
            portal: .unauthenticated,
            internet: .unreachable,
            environmentLabel: "宿舍网络",
            environmentReason: "verified_campus_source_ip",
            gatewayReason: "gateway_reachable",
            internetReason: "skipped_session_offline",
            autoLoginPaused: false
        ),
        probeDelay: Duration? = nil
    ) {
        self.probeResult = probeResult
        self.probeDelay = probeDelay
    }

    func currentCalls() -> BoundaryFakeCalls { calls }

    func probe() async throws -> SZUNETProbeResult {
        calls.probe += 1
        if let probeDelay {
            try await Task.sleep(for: probeDelay)
        }
        var result = probeResult
        result.autoLoginPaused = paused
        return result
    }

    func manualLogin() async -> SZUNETActionResult {
        calls.manualLogin += 1
        return SZUNETActionResult(
            outcome: .authenticated,
            title: "手动登录成功",
            reason: "session_verified"
        )
    }

    func automaticLogin() async -> SZUNETActionResult {
        calls.automaticLogin += 1
        return SZUNETActionResult(
            outcome: .authenticated,
            title: "自动登录成功",
            reason: "session_verified"
        )
    }

    func manualLogout() async -> SZUNETActionResult {
        calls.manualLogout += 1
        paused = true
        return SZUNETActionResult(
            outcome: .loggedOut,
            title: "已退出",
            reason: "session_verified"
        )
    }

    func setAutoLoginEnabled(_ enabled: Bool) async throws {
        calls.setAutoLogin += 1
        paused = !enabled
    }

    func configurationSummary() async throws -> SZUNETConfigurationSummary {
        calls.configuration += 1
        return SZUNETConfigurationSummary(
            username: "student",
            portalHost: "drcom.example.invalid",
            sourceNetworkCount: 2
        )
    }

    func saveCredentials(username _: String, password _: String?) async throws {
        calls.credentialWrites += 1
    }
}
