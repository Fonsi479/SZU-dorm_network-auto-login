import Foundation
import Testing
@testable import SZUNetCore

@Suite("Teaching SRun provider", .serialized)
struct TeachingSRunProviderTests {
    @Test("probe is offline-only and derives dynamic portal configuration")
    func verifiedProbeUsesNoTransport() async throws {
        let transport = QueueSRunTransport([])
        let provider = TeachingSRunProvider(transport: transport)
        let probe = await provider.probeEnvironment(try context())

        #expect(probe.isVerified)
        #expect(probe.acid == "5")
        #expect(await transport.requests().isEmpty)
    }

    @Test("login ACK requires matching online status confirmation")
    func loginRequiresPostAckConfirmation() async throws {
        let transport = QueueSRunTransport([
            try fixtureData("challenge_success.jsonp"),
            try fixtureData("login_success.jsonp"),
            try fixtureData("status_online.jsonp"),
        ])
        let callbacks = CallbackSequence(["_szu_cb_7f31", "_szu_cb_d911", "_szu_cb_9001"])
        let provider = TeachingSRunProvider(
            transport: transport,
            callbackFactory: { callbacks.next() },
            clockMilliseconds: { 1 }
        )
        let context = try context()
        let probe = await provider.probeEnvironment(context)
        let result = await provider.login(
            context,
            probe: probe,
            username: "student-REDACTED@hlw",
            credential: CredentialHandle("synthetic-only")
        )
        let requests = await transport.requests()

        #expect(result.outcome == .succeeded)
        #expect(requests.map(\.path) == [
            "/cgi-bin/get_challenge", "/cgi-bin/srun_portal", "/cgi-bin/rad_user_info",
        ])
        #expect(requests.allSatisfy { $0.sourceIP == "198.51.100.27" })
        #expect(requests[1].query["ac_id"] == "5")
        #expect(requests[1].query["enc_ver"] == "srun_bx1")
        #expect(requests[1].query["password"]?.hasPrefix("{MD5}") == true)
        #expect(requests[1].query["info"]?.hasPrefix("{SRBX1}") == true)
    }

    @Test("already-online ACK queries status and does not repeat login")
    func alreadyOnlineIsConfirmed() async throws {
        let transport = QueueSRunTransport([
            try fixtureData("challenge_success.jsonp"),
            try fixtureData("already_online.jsonp"),
            try fixtureData("status_online.jsonp"),
        ])
        let callbacks = CallbackSequence(["_szu_cb_7f31", "_szu_cb_221a", "_szu_cb_9001"])
        let provider = TeachingSRunProvider(
            transport: transport,
            callbackFactory: { callbacks.next() }
        )
        let context = try context()
        let probe = await provider.probeEnvironment(context)
        let result = await provider.login(
            context,
            probe: probe,
            username: "student-REDACTED@hlw",
            credential: CredentialHandle("synthetic-only")
        )

        #expect(result.outcome == .unchanged)
        #expect(await transport.requests().filter { $0.path == "/cgi-bin/srun_portal" }.count == 1)
    }

    @Test("unknown status never becomes offline and logout remains disabled")
    func unknownAndLogoutDisabled() async throws {
        let transport = QueueSRunTransport([Data(#"_szu_cb_unknown({"error":"mystery"});"#.utf8)])
        let provider = TeachingSRunProvider(
            transport: transport,
            callbackFactory: { "_szu_cb_unknown" }
        )
        let context = try context()
        let probe = await provider.probeEnvironment(context)
        let status = await provider.sessionStatus(context, probe: probe, username: "synthetic")
        let logout = await provider.logout(context, probe: probe, username: "synthetic")

        #expect(status.state == .unknown)
        #expect(logout.errorCode == "SRUN_LOGOUT_DISABLED")
        #expect(await transport.requests().count == 1)
    }

    private func context() throws -> CampusNetworkContext {
        CampusNetworkContext(
            generation: 0,
            portalURL: try #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc")),
            portalHTML: try String(contentsOf: fixtureURL("portal_acid_5_sanitized.html"), encoding: .utf8),
            sourceInterface: "fixture0",
            sourceIP: "198.51.100.27",
            sourceRouteBound: true,
            teachingPortalIdentityVerified: true
        )
    }

    private func fixtureData(_ name: String) throws -> Data { try Data(contentsOf: fixtureURL(name)) }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol-spec/fixtures/\(name)")
    }
}

private struct SRunRecordedRequest: Equatable, Sendable {
    let path: String
    let query: [String: String]
    let sourceIP: String
}

private actor QueueSRunTransport: SRunTransporting {
    private var responses: [Data]
    private var recorded: [SRunRecordedRequest] = []

    init(_ responses: [Data]) {
        self.responses = responses
    }

    func get(
        path: String,
        query: [String: String],
        baseURL: URL,
        sourceIP: String,
        timeout: TimeInterval
    ) async throws -> SRunTransportResponse {
        recorded.append(SRunRecordedRequest(path: path, query: query, sourceIP: sourceIP))
        guard !responses.isEmpty else { throw SZUNetError.network("fixture_exhausted") }
        return SRunTransportResponse(
            statusCode: 200,
            body: responses.removeFirst(),
            finalURL: baseURL
        )
    }

    func requests() -> [SRunRecordedRequest] { recorded }
}

private final class CallbackSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) { self.values = values }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? "_szu_cb_exhausted" : values.removeFirst()
    }
}
