import Foundation
import Testing
@testable import SZUNETFeature

private actor FakeSZUNETDriver: SZUNETCoordinatorDriving {
    private(set) var probeCount = 0
    private(set) var loginCount = 0
    private(set) var logoutCount = 0
    private(set) var credentialWriteCount = 0

    func probe() async throws -> SZUNETProbeResult {
        probeCount += 1
        return SZUNETProbeResult(
            environment: .eligible,
            portal: .unauthenticated,
            internet: .unreachable,
            environmentLabel: "fixture",
            environmentReason: "fixture",
            gatewayReason: "fixture",
            internetReason: "fixture",
            autoLoginPaused: false
        )
    }

    func manualLogin() async -> SZUNETActionResult {
        loginCount += 1
        return SZUNETActionResult(outcome: .authenticated, title: "fixture")
    }

    func automaticLogin() async -> SZUNETActionResult {
        loginCount += 1
        return SZUNETActionResult(outcome: .authenticated, title: "fixture")
    }

    func manualLogout() async -> SZUNETActionResult {
        logoutCount += 1
        return SZUNETActionResult(outcome: .loggedOut, title: "fixture")
    }

    func setAutoLoginEnabled(_: Bool) async throws {}

    func configurationSummary() async throws -> SZUNETConfigurationSummary {
        SZUNETConfigurationSummary(username: "fixture", portalHost: "fixture", sourceNetworkCount: 1)
    }

    func saveCredentials(username _: String, password _: String?) async throws {
        credentialWriteCount += 1
    }

    func counts() -> (Int, Int, Int, Int) {
        (probeCount, loginCount, logoutCount, credentialWriteCount)
    }
}

@Suite("SZUNET public module boundary")
struct SZUNETModuleTests {
    @Test("disabled module never constructs or calls the credential driver")
    func disabledModuleIsPassive() async {
        let driver = FakeSZUNETDriver()
        let module = SZUNETModule(driverFactory: { driver })

        let snapshot = await module.configure(featureEnabled: false, autoLoginEnabled: false)
        _ = await module.refresh()
        _ = await module.manualLogin()
        _ = await module.manualLogout()
        _ = await module.saveCredentials(username: "fixture", password: "fixture")

        #expect(!snapshot.status.featureEnabled)
        let counts = await driver.counts()
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
        #expect(counts.2 == 0)
        #expect(counts.3 == 0)
    }

    @Test("manual login and logout stay wired to the real module boundary")
    func manualActionsUseDriver() async {
        let driver = FakeSZUNETDriver()
        let module = SZUNETModule(driverFactory: { driver })

        _ = await module.configure(featureEnabled: true, autoLoginEnabled: false)
        let loggedIn = await module.manualLogin()
        let loggedOut = await module.manualLogout()

        #expect(loggedIn.status.portal == .authenticated)
        #expect(loggedOut.status.portal == .unauthenticated)
        let counts = await driver.counts()
        #expect(counts.1 == 1)
        #expect(counts.2 == 1)
    }
}
