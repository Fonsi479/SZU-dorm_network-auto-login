import Foundation
import Testing
@testable import SZUNetCore

@Suite("SRun strict parsing and discovery")
struct SRunProtocolTests {
    @Test("dynamic ACID fixtures are discovered without a global constant")
    func dynamicDiscovery() throws {
        let acid5 = try fixtureText("portal_acid_5_sanitized.html")
        let dynamic = try fixtureText("portal_dynamic_acid_sanitized.html")
        let first = try SRunPortalDiscovery.discover(
            entryURL: #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc")),
            pageHTML: acid5,
            sourceIP: "198.51.100.27"
        )
        let second = try SRunPortalDiscovery.discover(
            entryURL: #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc")),
            pageHTML: dynamic,
            sourceIP: "203.0.113.41"
        )

        #expect(first.acid == "5")
        #expect(second.acid == "17")
    }

    @Test("URL, page, and bound-route conflicts fail closed")
    func discoveryConflict() throws {
        let html = try fixtureText("portal_dynamic_acid_sanitized.html")
        #expect(throws: SRunPortalDiscoveryError.self) {
            _ = try SRunPortalDiscovery.discover(
                entryURL: #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc?ac_id=5")),
                pageHTML: html,
                sourceIP: "203.0.113.41"
            )
        }
        #expect(throws: SRunPortalDiscoveryError.self) {
            _ = try SRunPortalDiscovery.discover(
                entryURL: #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc")),
                pageHTML: html,
                sourceIP: "198.51.100.99"
            )
        }
    }

    @Test("JSONP requires exact callback, one object, size bound, and no trailing script")
    func strictJSONP() throws {
        let success = try fixtureData("challenge_success.jsonp")
        let decoded = try SRunJSONP.decode(success, expectedCallback: "_szu_cb_7f31")
        #expect(decoded["res"] as? String == "ok")
        #expect(throws: SRunJSONPError.self) {
            _ = try SRunJSONP.decode(success, expectedCallback: "wrong_callback")
        }
        #expect(throws: SRunJSONPError.self) {
            _ = try SRunJSONP.decode(try fixtureData("malformed_response.txt"), expectedCallback: "_szu_cb_expected")
        }
        #expect(throws: SRunJSONPError.self) {
            _ = try SRunJSONP.decode(Data(repeating: 0x78, count: SRunJSONP.maximumBytes + 1), expectedCallback: "cb")
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureRoot().appendingPathComponent(name))
    }

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: fixtureRoot().appendingPathComponent(name), encoding: .utf8)
    }

    private func fixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("protocol-spec/fixtures", isDirectory: true)
    }
}
