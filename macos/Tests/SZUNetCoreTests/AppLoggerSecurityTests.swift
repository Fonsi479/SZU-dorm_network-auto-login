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
}
