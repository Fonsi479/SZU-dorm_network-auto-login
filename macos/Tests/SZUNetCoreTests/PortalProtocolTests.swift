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

    @Test("Dorm online-list counts distinct account devices from server MAC/IP")
    func onlineListCountsDistinctDevices() async {
        var configuration = AppConfiguration.default
        configuration.auth.accountPrefix = ",1,"
        let records = [
            #"{"user_account":"  ,1,student  ","online_ip":"172.24.59.154","online_mac":"AA:BB:CC:DD:EE:01"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.155","online_mac":"aabbccddee01"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.156","online_mac":"000000000000"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.156","online_mac":"111111111111"}"#,
            #"{"user_account":",1,other","online_ip":"172.24.59.199","online_mac":"aabbccddee99"}"#,
        ].joined(separator: ",")
        let transport = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response("dr9999({\"list\":[" + records + "]});"),
        ])

        let fact = await PortalSessionReader(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionFact(username: "  ,1,student  ", sourceIP: sourceIP)

        #expect(fact.onlineDeviceCount == 2)
        #expect(fact.onlineDeviceLimit == 3)
        #expect(fact.exactOnlineRecordPresent == true)
        #expect(fact.account == "student")
        #expect(fact.state == .offline, "chkstatus explicitly reported this IP offline")

        let clientTransport = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response("dr9999({\"list\":[" + records + "]});"),
        ])
        let publicSession = await DrCOMClient(
            configuration: configuration,
            transport: clientTransport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionStatus(username: "student", sourceIP: sourceIP)
        #expect(publicSession.exactOnlineRecordPresent == true)
    }

    @Test("Dorm online-list count supports 0 through 3 devices and account prefixes")
    func onlineListCountBoundaries() async {
        var configuration = AppConfiguration.default
        configuration.auth.accountPrefix = ",1,"
        let deviceRecords = [
            #"{"user_account":",1,student","online_ip":"172.24.59.160","online_mac":"aabbccddee10"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.161","online_mac":"aabbccddee11"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.162","online_mac":"aabbccddee12"}"#,
        ]

        for count in 0...3 {
            let list = deviceRecords.prefix(count).joined(separator: ",")
            let transport = QueueTransport(responses: [
                response(#"dr1002({"result":0,"uid":" ,1,student ","ss5":"172.24.59.154"});"#),
                response("dr9999({\"list\":[" + list + "]});"),
            ])
            let fact = await PortalSessionReader(
                configuration: configuration,
                transport: transport,
                logger: AppLogger(fileURL: temporaryLogURL())
            ).sessionFact(username: "student", sourceIP: sourceIP)
            #expect(fact.onlineDeviceCount == count)
            #expect(fact.onlineDeviceLimit == 3)
        }
    }

    @Test("unreadable or malformed Dorm online-list fails closed with unknown count")
    func onlineListUnknownCountFailsClosed() async {
        var configuration = AppConfiguration.default
        configuration.auth.accountPrefix = ",1,"
        let unreadable = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response(#"dr9999({"unexpected":true});"#),
        ])
        let unreadableStatus = await DrCOMClient(
            configuration: configuration,
            transport: unreadable,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionStatus(username: "student", sourceIP: sourceIP)
        #expect(unreadableStatus.state == .unknown)
        #expect(unreadableStatus.errorCode == "SESSION_UNKNOWN")
        #expect(unreadableStatus.exactOnlineRecordPresent == nil)
        #expect(unreadableStatus.onlineDeviceCount == nil)
        #expect(unreadableStatus.onlineDeviceLimit == 3)

        let malformed = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response(#"dr9999({"list":[{"user_account":" ,1,student "}]});"#),
        ])
        let malformedFact = await PortalSessionReader(
            configuration: configuration,
            transport: malformed,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionFact(username: "student", sourceIP: sourceIP)
        #expect(malformedFact.onlineDeviceCount == nil)
        #expect(malformedFact.onlineDeviceLimit == 3)

        let missingAccount = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response(#"dr9999({"list":[{"user_account":"student","online_ip":"172.24.59.160"},{"online_ip":"172.24.59.161","online_mac":"aabbccddee11"}]});"#),
        ])
        let missingAccountFact = await PortalSessionReader(
            configuration: configuration,
            transport: missingAccount,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionFact(username: "student", sourceIP: sourceIP)
        #expect(missingAccountFact.onlineDeviceCount == nil)

        let overLimitRecords = (0..<4).map { index in
            "{\"user_account\":\",1,student\",\"online_ip\":\"172.24.59.\(160 + index)\",\"online_mac\":\"aabbccddee1\(index)\"}"
        }.joined(separator: ",")
        let overLimit = QueueTransport(responses: [
            response(#"dr1002({"result":0,"uid":"student","ss5":"172.24.59.154"});"#),
            response("dr9999({\"list\":[" + overLimitRecords + "]});"),
        ])
        let overLimitFact = await PortalSessionReader(
            configuration: configuration,
            transport: overLimit,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionFact(username: "student", sourceIP: sourceIP)
        #expect(overLimitFact.onlineDeviceCount == 3)
    }

    @Test("exact local session remains distinct from same-account remote sessions")
    func exactLocalSessionAndAccountCountAreSeparate() async {
        var configuration = AppConfiguration.default
        configuration.auth.accountPrefix = ",1,"
        let list = [
            #"{"user_account":",1,student","online_ip":"172.24.59.154","online_mac":"aabbccddee01"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.155","online_mac":"aabbccddee02"}"#,
            #"{"user_account":",1,student","online_ip":"172.24.59.156","online_mac":"aabbccddee03"}"#,
        ].joined(separator: ",")
        let transport = QueueTransport(responses: [
            response(#"dr1002({"uid":" ,1,student ","ss5":"172.24.59.154"});"#),
            response("dr9999({\"list\":[" + list + "]});"),
        ])
        let status = await DrCOMClient(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionStatus(username: "student", sourceIP: sourceIP)

        #expect(status.state == .online)
        #expect(status.accountMatch == .matches)
        #expect(status.clientIP == sourceIP)
        #expect(status.onlineDeviceCount == 3)
        #expect(status.onlineDeviceLimit == 3)
    }

    @Test("a status response for another account cannot satisfy the requested session")
    func statusAccountMismatchFailsClosed() async {
        var configuration = AppConfiguration.default
        configuration.auth.accountPrefix = ",1,"
        let transport = QueueTransport(responses: [
            response(#"dr1002({"result":1,"uid":" ,1,other ","ss5":"172.24.59.154"});"#),
            response(#"dr9999({"list":[]});"#),
        ])
        let status = await DrCOMClient(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).sessionStatus(username: "student", sourceIP: sourceIP)

        #expect(status.state == .unknown)
        #expect(status.accountMatch == .differs)
        #expect(status.onlineDeviceCount == 0)
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

    @Test("accepted unbind proceeds directly to explicit logout and one final verification")
    func acceptedUnbindDoesNotAddAFullVerificationCycle() async {
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        let transport = QueueTransport(responses: [
            response("v46ip='172.24.59.154';vlanid=\"0\";ss4=\"000000000000\";"),
            response("dr1002({\"result\":1,\"uid\":\"student\",\"ss5\":\"172.24.59.154\",\"ss4\":\"000000000000\"});"),
            response("dr9999({\"list\":[{\"user_account\":\"student\",\"online_ip\":\"172.24.59.154\",\"online_mac\":\"9eb56a2011e4\"}]});"),
            response("dr1003({\"result\":1,\"data\":{\"un_bind_mac\":1,\"register_mode\":1,\"isp_unbind_suffix\":0,\"ac_logout\":0,\"check_online_method\":0,\"login_method\":1}});"),
            response("dr1003({\"result\":1,\"msg\":\"解绑终端MAC成功\"});"),
            response("dr1004({\"result\":1,\"msg\":\"Portal协议注销成功！\"});"),
            response("dr1002({\"result\":0,\"uid\":\"\",\"ss5\":\"172.24.59.154\",\"ss4\":\"000000000000\"});"),
        ])

        let result = await PortalLogoutTransaction(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).execute(username: "student", sourceIP: sourceIP)

        #expect(result.status == .success)
        #expect(result.reason == "portal_logout_verified")
        let paths = transport.requests.map(\.url.path)
        let unbindIndex = paths.firstIndex { $0.hasSuffix("/mac/unbind") }
        let logoutIndex = paths.firstIndex { $0.hasSuffix("/portal/logout") }
        #expect(unbindIndex != nil)
        #expect(logoutIndex == unbindIndex.map { $0 + 1 })
        #expect(paths.filter { $0.hasSuffix("/drcom/chkstatus") }.count == 2)
        #expect(transport.responses.isEmpty)
    }

    @Test("an unfamiliar login response is recovered only by an exact online session")
    func ambiguousLoginResponseUsesVerifiedSession() async {
        var configuration = AppConfiguration.default
        configuration.user.username = "student"
        let transport = QueueTransport(responses: [
            response("dr1003({\"message\":\"changed response envelope\"});"),
            response("dr1002({\"result\":1,\"uid\":\"student\",\"ss5\":\"172.24.59.154\"});"),
            response("dr9999({\"list\":[{\"user_account\":\"student\",\"online_ip\":\"172.24.59.154\"}]});"),
        ])

        let result = await DrCOMClient(
            configuration: configuration,
            transport: transport,
            logger: AppLogger(fileURL: temporaryLogURL())
        ).login(username: "student", password: "fixture", knownSourceIP: sourceIP)

        #expect(result.status == .success)
        #expect(result.reason == "session_verified")
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
