import Foundation
import Testing
import SZUNetCore
@testable import SZUDormLoginApp

@Suite("Standalone app automation ownership", .serialized)
struct AppAutomationOwnershipTests {
    @Test("standalone host advertises ownership protocol capability")
    @MainActor
    func standaloneHostMarker() {
        #expect(AppAutomationOwnership.host.hostID == "com.szu-netlogin.dorm-login")
        #expect(AppAutomationOwnership.host.bundleID == "com.szu-netlogin.dorm-login")
        #expect(AppAutomationOwnership.host.supportsOwnershipProtocol)
    }

    @Test("empty store is claimed and clean shutdown retains the owner")
    @MainActor
    func claimsAndRetainsOwnershipAfterStop() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.remove() }

        let gate = AppAutomationOwnership(store: fixture.store())
        #expect(gate.start())
        #expect(gate.verifyOwner())
        #expect(gate.snapshot.ownerRunning)

        gate.stop()
        #expect(gate.snapshot.isCurrentHostOwner)
        #expect(!gate.snapshot.ownerRunning)

        let second = AppAutomationOwnership(
            store: fixture.store(),
            descriptor: CampusAutomationHost(
                hostID: "com.example.other-client",
                displayName: "Other Client",
                bundleID: "com.example.other-client"
            )
        )
        #expect(!second.start())
        #expect(second.snapshot.currentOwner?.hostID == AppAutomationOwnership.host.hostID)
        #expect(!second.verifyOwner())
    }

    @Test("legacy owner marker blocks an implicit takeover")
    @MainActor
    func legacyOwnerRequiresUpgrade() throws {
        let fixture = try OwnershipFixture()
        defer { fixture.remove() }

        let legacy = CampusAutomationHost(
            hostID: "com.szu-netlogin.legacy",
            displayName: "旧版 SZU Dorm Login",
            bundleID: "com.szu-netlogin.legacy"
        )
        let gate = AppAutomationOwnership(
            store: fixture.store(legacyOwner: legacy)
        )

        #expect(!gate.start())
        #expect(gate.snapshot.currentOwner?.hostID == legacy.hostID)
        #expect(gate.snapshot.currentOwner?.supportsOwnershipProtocol == false)
        #expect(throws: CampusAutomationOwnershipError.legacyOwnerRequiresUpgrade(
            legacy.displayName
        )) {
            try gate.transferOwnership()
        }
    }

    @Test("standalone runtime paths do not fall back to the legacy coordinator")
    func standaloneUsesEmbeddedRuntime() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("macos/Sources/SZUDormLogin")
        let network = try String(
            contentsOf: sources.appendingPathComponent("AppModel+Network.swift"),
            encoding: .utf8
        )
        let actions = try String(
            contentsOf: sources.appendingPathComponent("AppModel+SessionActions.swift"),
            encoding: .utf8
        )
        let configuration = try String(
            contentsOf: sources.appendingPathComponent("AppModel+Configuration.swift"),
            encoding: .utf8
        )
        let commandLine = try String(
            contentsOf: sources.appendingPathComponent("CommandLineRunner.swift"),
            encoding: .utf8
        )

        #expect(network.contains("embeddedRuntime.recoverAutomatically()"))
        #expect(network.contains("embeddedRuntime.refreshProduct()"))
        #expect(!network.contains("automation.startAutoLogin("))
        #expect(!network.contains("embeddedRuntime.login(automatic: true)"))
        #expect(!network.contains("coordinator.probe()"))
        #expect(actions.contains("embeddedRuntime.login()"))
        #expect(actions.contains("embeddedRuntime.logout(providerID: .dorm)"))
        #expect(!actions.contains("coordinator.loginNow()"))
        #expect(!actions.contains("coordinator.logout()"))
        #expect(configuration.contains("embeddedRuntime.savePassword"))
        #expect(!configuration.contains("coordinator.savePassword"))
        #expect(!configuration.contains("KeychainStore()"))
        #expect(commandLine.contains("import SZUNETEmbedded"))
        #expect(!commandLine.contains("coordinator.checkAndLogin()"))
        #expect(!commandLine.contains("coordinator.loginNow()"))
        #expect(!commandLine.contains("coordinator.logout()"))
        #expect(commandLine.contains("--force-login"))
    }
}

private struct OwnershipFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("szu-netlogin-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func store(legacyOwner: CampusAutomationHost? = nil) -> CampusAutomationStore {
        CampusAutomationStore(
            fileURL: directory.appendingPathComponent("automation.json"),
            lockFileURL: directory.appendingPathComponent("automation.lock"),
            legacyOwner: legacyOwner
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
