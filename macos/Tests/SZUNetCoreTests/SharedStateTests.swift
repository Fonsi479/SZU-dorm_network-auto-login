import Foundation
import Testing
@testable import SZUNetCore

@Suite("Shared campus state", .serialized)
struct SharedStateTests {
    @Test("automation ownership is unique, explicit, and never auto-transferred")
    func uniqueOwnership() throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CampusAutomationStore(fileURL: root.appendingPathComponent("automation.json"))
        let standalone = CampusAutomationHost(
            hostID: "standalone", displayName: "Standalone", bundleID: "example.standalone"
        )
        let manager = CampusAutomationHost(
            hostID: "manager", displayName: "Manager", bundleID: "example.manager"
        )

        #expect(try store.claimOwnership(for: standalone).isCurrentHostOwner)
        #expect(throws: CampusAutomationOwnershipError.self) {
            _ = try store.claimOwnership(for: manager)
        }
        #expect(try store.verifyOwnership(hostID: "standalone"))
        #expect(!(try store.verifyOwnership(hostID: "manager")))

        let transferred = try store.transferOwnership(to: manager)
        #expect(transferred.currentOwner == manager)
        #expect(transferred.isCurrentHostOwner)
        _ = try store.releaseOwnership(hostID: "manager")
        #expect(try store.load().owner == nil)
        #expect(!(try store.verifyOwnership(hostID: "standalone")))
    }

    @Test("legacy owner blocks transfer until its client is upgraded")
    func legacyOwnerBlocksTransfer() throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = CampusAutomationHost(
            hostID: "legacy", displayName: "Legacy App", bundleID: "example.legacy"
        )
        let store = CampusAutomationStore(
            fileURL: root.appendingPathComponent("automation.json"),
            legacyOwner: legacy
        )
        let manager = CampusAutomationHost(
            hostID: "manager", displayName: "Manager", bundleID: "example.manager"
        )

        let snapshot = try store.ownershipSnapshot(for: "manager")
        #expect(snapshot.currentOwner?.supportsOwnershipProtocol == false)
        #expect(!snapshot.canTransfer)
        #expect(throws: CampusAutomationOwnershipError.self) {
            _ = try store.transferOwnership(to: manager)
        }

        let upgraded = try store.refreshOwnerCapability(
            hostID: legacy.hostID,
            supportsOwnershipProtocol: true
        )
        #expect(upgraded.currentOwner?.supportsOwnershipProtocol == true)
        #expect(try store.transferOwnership(to: manager).isCurrentHostOwner)
        #expect(throws: CampusAutomationOwnershipError.self) {
            _ = try store.refreshOwnerCapability(
                hostID: legacy.hostID,
                supportsOwnershipProtocol: false
            )
        }
    }

    @Test("automation state is private, normalized, and rejects symlink targets")
    func secureAutomationPersistence() throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private/automation.json")
        let store = CampusAutomationStore(fileURL: file)
        let configuration = try store.updateProbe(enabled: true, intervalSeconds: 7)
        let fileMode = try permissions(file)
        let directoryMode = try permissions(file.deletingLastPathComponent())

        #expect(configuration.probeIntervalSeconds == 30)
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)

        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("linked-automation.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedStore = CampusAutomationStore(fileURL: link)
        #expect(throws: (any Error).self) { _ = try linkedStore.load() }
    }

    @Test("provider settings writes serialize across a process lock")
    func providerSettingsUseCrossProcessLock() async throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("providers.json")
        let lock = root.appendingPathComponent("providers.lock")
        let store = CampusProviderSettingsStore(fileURL: file, lockFileURL: lock)
        let holder = try ExternalFileLockHolder(lockURL: lock)
        let task = Task.detached { try store.save(.default) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        holder.stop()
        try await task.value
        #expect(try permissions(file) == 0o600)
    }

    @Test("pause state rejects symbolic links and fails closed")
    func pauseStateRejectsSymlink() throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("outside-pause.json")
        try Data("{\"mode\":\"until\",\"pausedAt\":\"2000-01-01T00:00:00Z\",\"resumeAfter\":\"2000-01-01T00:01:00Z\"}".utf8)
            .write(to: target)
        let link = root.appendingPathComponent("pause.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = PauseStore(fileURL: link)

        #expect(store.activeState()?.mode == .manual)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("legacy configuration updates serialize across a process lock")
    func legacyConfigurationUsesCrossProcessLock() async throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
            logDirectory: root.appendingPathComponent("logs", isDirectory: true)
        )
        let store = ConfigurationStore(paths: paths, legacyCandidates: [])
        let holder = try ExternalFileLockHolder(lockURL: paths.configurationLockFile)
        let task = Task.detached { try store.save(.default) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!FileManager.default.fileExists(atPath: paths.configurationFile.path))
        holder.stop()
        try await task.value
        #expect(try permissions(paths.configurationFile) == 0o600)
        #expect(try permissions(paths.applicationSupportDirectory) == 0o700)
    }

    @Test("shared credentials read shared first then copy a legacy value without deletion")
    func progressiveCredentialMigration() async throws {
        let root = temporarySharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = CampusProviderSettingsStore(fileURL: root.appendingPathComponent("providers.json"))
        var configuration = CampusProductConfiguration.default
        configuration.dorm.credentialReference = "student-ref"
        try settingsStore.save(configuration)
        let credentials = FakeAccessGroupCredentialStore()
        credentials.values[.init(service: "legacy-service", account: "student-ref", group: nil)] = "synthetic"
        let broker = CampusKeychainCredentialBroker(
            settingsStore: settingsStore,
            credentialStore: credentials,
            accessMode: .shared(
                accessGroup: "TEAM.shared",
                legacyLocations: [
                    .init(provider: .teaching, service: "wrong-provider-service"),
                    .init(provider: .dorm, service: "legacy-service"),
                ]
            )
        )

        #expect(try await broker.openCredential(for: .dorm, username: "label") != nil)
        let sharedKey = FakeCredentialKey(service: "szu-netlogin", account: "student-ref", group: "TEAM.shared")
        #expect(credentials.values[sharedKey] == "synthetic")
        #expect(credentials.deleted.isEmpty)
        #expect(!credentials.reads.contains {
            $0.service == "wrong-provider-service"
        })
        credentials.reads.removeAll()
        #expect(try await broker.openCredential(for: .dorm, username: "label") != nil)
        #expect(credentials.reads == [sharedKey])
    }
}

private struct FakeCredentialKey: Hashable {
    let service: String
    let account: String
    let group: String?
}

private final class FakeAccessGroupCredentialStore: AccessGroupCredentialStoring, @unchecked Sendable {
    var values: [FakeCredentialKey: String] = [:]
    var reads: [FakeCredentialKey] = []
    var deleted: [FakeCredentialKey] = []

    func password(service: String, account: String, accessGroup: String?) throws -> String? {
        let key = FakeCredentialKey(service: service, account: account, group: accessGroup)
        reads.append(key)
        return values[key]
    }

    func setPassword(_ password: String, service: String, account: String, accessGroup: String?) throws {
        values[FakeCredentialKey(service: service, account: account, group: accessGroup)] = password
    }

    func deletePassword(service: String, account: String, accessGroup: String?) throws {
        let key = FakeCredentialKey(service: service, account: account, group: accessGroup)
        deleted.append(key)
        values.removeValue(forKey: key)
    }
}

private func temporarySharedRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-shared-state-tests-\(UUID().uuidString)", isDirectory: true)
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
