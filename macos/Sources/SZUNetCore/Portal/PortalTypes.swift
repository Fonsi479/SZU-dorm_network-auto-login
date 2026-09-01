import Foundation

enum PortalSessionState: Equatable {
    case online
    case offline
    case unknown
}

struct PortalRuntimeSettings {
    var unbindMAC = false
    var registerMode = 0
    var ispUnbindSuffix = false
    var acLogout = 0
    var checkOnlineMethod = 0
    var loginMethod = 1

    var shouldUnbindMAC: Bool {
        unbindMAC && (registerMode == 1 || registerMode == 4)
    }

    /// Mirrors the deployed a40.js logout dispatcher. Portal login methods 1
    /// and 9 (or an explicit AC logout mode) use eportal/portal/logout; local
    /// web-mode sessions use drcom/logout.
    var usesPortalLogout: Bool {
        (acLogout > 0 && loginMethod != 14) || loginMethod == 1 || loginMethod == 9
    }
}

struct PortalPageContext {
    var url: URL?
    var text = ""
    var variables: [String: String] = [:]
    var declaredLogoutURL: URL?
}

struct PortalSessionFact {
    var state: PortalSessionState = .unknown
    var account = ""
    var ip = ""
    var mac = ""
    var vlan = "0"
    var acIP = ""
    var acName = ""
    var statusWasReadable = false
    var onlineListWasReadable = false
    var exactOnlineRecordPresent: Bool?
    /// Distinct server-reported sessions for this account.  A missing value is
    /// intentionally different from zero: it means the list was unavailable
    /// or contained an identity we could not count safely.
    var onlineDeviceCount: Int?
    var onlineDeviceLimit: Int? = CampusOnlineDevicePolicy.dormLimit

    func matches(
        username: String,
        sourceIP: String,
        accountPrefix: String = ""
    ) -> Bool {
        let expectedAccount = PortalAccountNormalizer.normalize(
            username,
            prefix: accountPrefix
        )
        let expectedIP = IPv4CIDR.normalized(sourceIP)
        let accountMatches = expectedAccount.isEmpty
            || PortalAccountNormalizer.normalize(account, prefix: accountPrefix) == expectedAccount
        let ipMatches = expectedIP.isEmpty || ip == expectedIP
        return state == .online && accountMatches && ipMatches
    }
}

struct PortalSessionSnapshot {
    var fact: PortalSessionFact
    var runtime: PortalRuntimeSettings
    var page: PortalPageContext

    func terminal(jsVersion: String) -> PortalTerminalParameters {
        PortalTerminalBuilder.build(
            pageURL: page.url?.absoluteString ?? "",
            pageText: page.text,
            onlineRecord: [
                "online_ip": fact.ip,
                "online_mac": fact.mac,
            ],
            sourceIP: fact.ip,
            jsVersion: jsVersion
        )
    }
}

struct PortalOnlineListResult {
    var readable = false
    var exactRecord: [String: Any]?
    var deviceCount: Int?
}

struct PortalStatusResult {
    var readable = false
    var declaredOnline: Bool?
    var account = ""
    var ip = ""
    var mac = ""
    var vlan = "0"
    var acIP = ""
    var acName = ""
}

/// Normalizes the account identity used by the Dorm portal without exposing or
/// persisting credentials.  The wire format commonly prefixes accounts with
/// `,1,`; both the configured prefix and surrounding whitespace are ignored
/// when comparing status and online-list records.
enum PortalAccountNormalizer {
    static func normalize(_ value: String, prefix: String = "") -> String {
        var normalized = value.filter { !$0.isWhitespace }
        let configuredPrefix = prefix.filter { !$0.isWhitespace }
        if !configuredPrefix.isEmpty, normalized.hasPrefix(configuredPrefix) {
            normalized.removeFirst(configuredPrefix.count)
        }
        return normalized
    }
}
