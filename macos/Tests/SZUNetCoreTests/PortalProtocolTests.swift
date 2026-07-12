import Foundation
import Testing
@testable import SZUNetCore

@Suite("SZU portal protocol", .serialized)
struct PortalProtocolTests {
    private let sourceIP = "172.24.59.154"
    private let serverMAC = "9eb56a2011e4"

    @Test("login omits guessed local MAC")
    func loginOmitsGuessedLocalMAC() {
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        let query = PortalRequestBuilder.login(
            configuration: configuration,
            username: "student",
            password: "secret",
            sourceIP: sourceIP
        )

        #expect(query["user_account"] == ",1,student")
        #expect(query["wlan_user_ip"] == sourceIP)
        #expect(query["wlan_user_mac"] == nil)
    }

    @Test("portal page sentinel outranks online-list identity for logout")
    func pageSentinelOutranksOnlineRecord() {
        let terminal = PortalTerminalBuilder.build(
            pageURL: "http://172.30.255.42/a79.htm",
            pageText: "v46ip='172.24.59.154';vlanid=\"0\";ss4=\"000000000000\";",
            onlineRecord: [
                "online_ip": sourceIP,
                "online_mac": serverMAC,
                "nas_ip": "704585388",
            ],
            sourceIP: sourceIP,
            jsVersion: "4.1.3"
        )

        #expect(terminal.ip == sourceIP)
        #expect(terminal.mac == "000000000000")
        #expect(terminal.wlanACIP.isEmpty, "online_list NAS IP must not overwrite browser page parameters")
    }

    @Test("portal logout mirrors dynamic browser parameters")
    func portalLogoutMirrorsBrowserParameters() {
        let terminal = PortalTerminalParameters(
            ip: sourceIP,
            mac: "000000000000",
            vlan: "0",
            wlanACIP: "",
            wlanACName: "",
            jsVersion: "4.1.3"
        )
        let runtime = PortalRuntimeSettings(
            unbindMAC: true,
            registerMode: 1,
            ispUnbindSuffix: false,
            acLogout: 0,
            checkOnlineMethod: 0,
            loginMethod: 1
        )
        let query = PortalRequestBuilder.portalLogout(
            configuration: .default,
            terminal: terminal,
            runtime: runtime
        )

        #expect(runtime.usesPortalLogout)
        #expect(query["login_method"] == "1")
        #expect(query["register_mode"] == "1")
        #expect(query["ac_logout"] == "0")
        #expect(query["wlan_user_mac"] == "000000000000")
        #expect(query["wlan_ac_ip"] == "")
    }

    @Test("live SZU logout transaction uses exact portal identity and verifies offline")
    func liveStyleLogoutTransaction() async {
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        let transport = QueueTransport(responses: [
            response("v46ip='172.24.59.154';vlanid=\"0\";ss4=\"000000000000\";"),
            response("dr1002({\"result\":1,\"uid\":\"student\",\"ss5\":\"172.24.59.154\",\"ss4\":\"000000000000\"});"),
            response("dr9999({\"list\":[{\"user_account\":\"student\",\"online_ip\":\"172.24.59.154\",\"online_mac\":\"9eb56a2011e4\",\"nas_ip\":\"704585388\"}]});"),
            response("dr1003({\"result\":1,\"data\":{\"un_bind_mac\":1,\"register_mode\":1,\"isp_unbind_suffix\":0,\"ac_logout\":0,\"check_online_method\":0,\"login_method\":1}});"),
            response("dr1003({\"result\":0,\"msg\":\"mac不存在\"});"),
            response("dr1004({\"result\":1,\"msg\":\"Portal协议注销成功！\"});"),
            response("dr1002({\"result\":0,\"uid\":\"\",\"ss5\":\"172.24.59.154\",\"ss4\":\"000000000000\"});"),
            response("dr9999({\"list\":[]});"),
        ])

        let result = await PortalLogoutTransaction(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).execute(username: "student", sourceIP: sourceIP)

        #expect(result.status == .success)
        #expect(result.reason == "portal_logout_verified")
        #expect(!transport.requests.contains { $0.url.path == "/drcom/logout" })

        let unbind = transport.requests.first { $0.url.path.hasSuffix("/mac/unbind") }
        #expect(unbind?.query["user_account"] == "student")
        #expect(unbind?.query["wlan_user_mac"] == serverMAC.uppercased())

        let logout = transport.requests.first { $0.url.path.hasSuffix("/portal/logout") }
        #expect(logout?.query["wlan_user_mac"] == "000000000000")
        #expect(logout?.query["wlan_ac_ip"] == "")
        #expect(logout?.query["login_method"] == "1")
        #expect(transport.responses.isEmpty)
    }

    @Test("JSONP classifier accepts numeric and string results")
    func classifierAcceptsNumericAndStringResults() {
        #expect(PortalResponseClassifier.success(PortalCodec.parseJSONP("cb({\"result\":1});")) == true)
        #expect(PortalResponseClassifier.success(PortalCodec.parseJSONP("cb({\"result\":\"1\"});")) == true)
        #expect(PortalResponseClassifier.success(PortalCodec.parseJSONP("cb({\"result\":0,\"msg\":\"失败\"});")) == false)
    }
}

private final class QueueTransport: HTTPTransporting {
    struct Request {
        var url: URL
        var query: [String: String]
    }

    var responses: [HTTPResponse]
    private(set) var requests: [Request] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func get(
        _ url: URL,
        query: [String: String],
        headers: [String: String],
        timeout: TimeInterval,
        sourceIP: String?
    ) async throws -> HTTPResponse {
        requests.append(Request(url: url, query: query))
        guard !responses.isEmpty else { throw SZUNetError.network("fixture_exhausted") }
        return responses.removeFirst()
    }
}

private func response(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: status,
        headers: [:],
        body: Data(body.utf8),
        finalURL: URL(string: "http://172.30.255.42/")!
    )
}

private func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-tests-\(UUID().uuidString).log")
}
