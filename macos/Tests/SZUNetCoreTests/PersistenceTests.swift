import Foundation
import Testing
@testable import SZUNetCore

@Suite("Configuration and pause persistence", .serialized)
struct PersistenceTests {
    @Test("legacy YAML fields are mapped without losing quoted portal parameters")
    func legacyYAMLMapping() throws {
        let configuration = try LegacyYAMLConfigurationParser.parse(
            """
            auth:
              login_url: "http://172.30.255.42:801/eportal/portal/login"
              logout_url: "http://172.30.255.42:801/eportal/portal/logout"
              account_prefix: ",1," # browser-compatible account form
              timeout_seconds: 9
            user:
              username: 'student'
            network:
              dorm_gateway_hosts:
                - 172.30.255.42
              campus_source_networks:
                - 172.16.0.0/12
              test_urls:
                - http://captive.apple.com/hotspot-detect.html
                - http://www.baidu.com/
            security:
              password_source: keychain
              keychain_service: szu-netlogin
            """
        )

        #expect(configuration.user.username == "student")
        #expect(configuration.auth.accountPrefix == ",1,")
        #expect(configuration.auth.timeoutSeconds == 9)
        #expect(configuration.auth.logoutURL.hasSuffix("/portal/logout"))
        #expect(configuration.network.gatewayHosts == ["172.30.255.42"])
        #expect(configuration.network.testURLs.count == 2)
    }

    @Test("configuration store migrates YAML once and writes private JSON")
    func configurationMigration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = testPaths(root: root)
        let legacyURL = root.appendingPathComponent("legacy-config.yaml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            """
            user:
              username: student
            network:
              test_urls:
                - http://captive.apple.com/hotspot-detect.html
                - http://www.baidu.com/
            """.utf8
        ).write(to: legacyURL)

        let store = ConfigurationStore(paths: paths, legacyCandidates: [legacyURL])
        let migrated = try store.load()
        let reloaded = try store.load()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.configurationFile.path)

        #expect(migrated.migratedFrom == legacyURL)
        #expect(migrated.configuration.user.username == "student")
        #expect(reloaded.migratedFrom == nil)
        #expect(reloaded.configuration == migrated.configuration)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("legacy pause marker migrates into the locked JSON state")
    func legacyPauseMigration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = testPaths(root: root)
        let legacyURL = root.appendingPathComponent("legacy-paused")
        try Data("paused\n".utf8).write(to: legacyURL)

        let store = PauseStore(
            fileURL: paths.pauseFile,
            lockFileURL: paths.pauseLockFile,
            legacyFileURL: legacyURL,
            migrationFileURL: paths.legacyPauseMigrationFile,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let state = store.activeState()

        #expect(state?.mode == .manual)
        #expect(FileManager.default.fileExists(atPath: paths.pauseFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.legacyPauseMigrationFile.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("pause writes wait for a cross-process advisory lock")
    func pauseWriteUsesCrossProcessLock() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = testPaths(root: root)
        let store = PauseStore(
            fileURL: paths.pauseFile,
            lockFileURL: paths.pauseLockFile,
            legacyFileURL: nil,
            migrationFileURL: paths.legacyPauseMigrationFile
        )
        let holder = try ExternalFileLockHolder(lockURL: paths.pauseLockFile)
        let started = Date()

        let writeTask = Task.detached {
            try store.pause()
            return Date()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!FileManager.default.fileExists(atPath: paths.pauseFile.path))

        holder.stop()
        let finished = try await writeTask.value

        #expect(finished.timeIntervalSince(started) >= 0.04)
        #expect(store.isPaused)
    }
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-persistence-tests-\(UUID().uuidString)", isDirectory: true)
}

private func testPaths(root: URL) -> AppPaths {
    AppPaths(
        applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
        logDirectory: root.appendingPathComponent("Logs", isDirectory: true)
    )
}
