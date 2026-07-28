import Foundation
import Testing
@testable import SZUNetCore

@Suite("Campus diagnostic redaction")
struct AppLoggerSecurityTests {
    @Test("logs never retain credentials, portal bodies, or account query values")
    func redactsSensitiveDiagnosticText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("app.log")
        let logger = AppLogger(fileURL: logURL)
        let password = ["synthetic", "campus", "password"].joined(separator: "-")
        let body = "synthetic-portal-response-body"
        let account = "synthetic-campus-account"

        logger.info(
            "user_account=\(account) user_password=\(password) portal_response=\(body)",
            password: password
        )
        let output = logger.tail()

        #expect(!output.contains(password))
        #expect(!output.contains(body))
        #expect(!output.contains(account))
        #expect(output.contains("[REDACTED]"))
    }

    @Test("logs redact auth material, full query URLs, SSIDs, and full IP addresses")
    func redactsProtocolAndNetworkIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-redaction-p0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(fileURL: directory.appendingPathComponent("app.log"))

        logger.info(
            "challenge=challenge-material info=info-material chksum=checksum-material "
                + "password={MD5}digest-material payload={SRBX1}encoded-material "
                + "url=http://portal.test/eportal/?user_account=student&token=token-material "
                + "ssid=SZU_PRIVATE_WIFI source_ip=172.24.59.154"
        )
        let output = logger.tail()

        for forbidden in [
            "challenge-material", "info-material", "checksum-material", "digest-material",
            "encoded-material", "user_account=student", "token-material", "SZU_PRIVATE_WIFI",
            "172.24.59.154",
        ] {
            #expect(!output.contains(forbidden))
        }
        #expect(output.contains("[REDACTED]"))
    }

    @Test("diagnostic export is mode 0600 and masks SSID and IP")
    func diagnosticExportIsPrivateAndSanitized() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("szunet-diagnostic-p0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            logDirectory: root.appendingPathComponent("Logs", isDirectory: true)
        )
        let configurationStore = ConfigurationStore(paths: paths, legacyCandidates: [])
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        try configurationStore.save(configuration)
        let coordinator = LoginCoordinator(
            configurationStore: configurationStore,
            credentials: DiagnosticCredentialStore(),
            pauseStore: PauseStore(
                fileURL: paths.pauseFile,
                lockFileURL: paths.pauseLockFile,
                legacyFileURL: nil,
                migrationFileURL: paths.legacyPauseMigrationFile
            ),
            networkProbe: DiagnosticNetworkProbe(),
            logger: AppLogger(fileURL: paths.logFile),
            clientFactory: { _ in DiagnosticDrCOMService() }
        )
        let reportURL = try await DiagnosticReportBuilder(
            paths: paths,
            coordinator: coordinator,
            logger: AppLogger(fileURL: paths.logFile)
        ).create()
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: reportURL.path)

        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!report.contains("SZU_PRIVATE_WIFI"))
        #expect(!report.contains("172.24.59.154"))
    }
}

private final class DiagnosticCredentialStore: CredentialStoring {
    func password(service: String, account: String) throws -> String? { nil }
    func setPassword(_ password: String, service: String, account: String) throws {}
    func deletePassword(service: String, account: String) throws {}
}

private final class DiagnosticNetworkProbe: NetworkProbing {
    func probeGateway(configuration: AppConfiguration) -> NetworkStatus {
        NetworkStatus(
            gatewayReachable: true,
            campusInternetOK: false,
            gatewayHost: "172.30.255.42",
            sourceIP: "172.24.59.154",
            gatewayReason: "connected"
        )
    }

    func probeInternet(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) async -> NetworkStatus { status }

    func classify(configuration: AppConfiguration, status: NetworkStatus) -> NetworkEnvironment {
        NetworkEnvironment(
            label: "宿舍网络",
            isDormNetwork: true,
            autoLoginAvailable: true,
            wifiSSID: "SZU_PRIVATE_WIFI",
            sourceIP: status.sourceIP,
            reason: "source_ip_verified"
        )
    }
}

private actor DiagnosticDrCOMService: DrCOMServicing {
    func login(username: String, password: String, knownSourceIP: String) async -> LoginResult {
        LoginResult(status: .failed, reason: "not_used")
    }

    func logout(username: String, knownSourceIP: String) async -> LogoutResult {
        LogoutResult(status: .unknown, reason: "not_used")
    }

    func isSessionOnline(username: String, sourceIP: String) async -> Bool? { false }
}
