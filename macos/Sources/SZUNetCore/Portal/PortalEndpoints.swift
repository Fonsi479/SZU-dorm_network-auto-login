import Foundation

struct PortalEndpoints {
    let configuration: AppConfiguration

    var loginURL: URL? {
        URL(string: configuration.auth.loginURL)
    }

    var pageURL: URL? {
        let configured = configuration.auth.logoutPageURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return URL(string: configured) }
        guard var components = URLComponents(string: configuration.auth.loginURL),
              components.host != nil else { return nil }
        components.port = nil
        components.path = "/a79.htm"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var portalAPIBaseURL: URL? {
        guard var components = URLComponents(string: configuration.auth.loginURL) else { return nil }
        let path = components.path
        if path.hasSuffix("/login") {
            components.path = String(path.dropLast("login".count))
        } else if !path.hasSuffix("/") {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func portalAPI(_ endpoint: String) -> URL? {
        guard let base = portalAPIBaseURL else { return nil }
        return URL(string: endpoint, relativeTo: base)?.absoluteURL
    }

    func drcom(_ endpoint: String) -> URL? {
        guard let pageURL,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/drcom/" + endpoint
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var unbindURL: URL? {
        let configured = configuration.auth.unbindURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? portalAPI("mac/unbind") : URL(string: configured)
    }

    var configuredOrPortalLogoutURL: URL? {
        let configured = configuration.auth.logoutURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? portalAPI("logout") : URL(string: configured)
    }

    func headers(refererURL: URL? = nil) -> [String: String] {
        let candidate = refererURL ?? pageURL ?? loginURL
        var referer = "http://172.30.255.42/"
        if let candidate,
           var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) {
            components.path = "/"
            components.query = nil
            components.fragment = nil
            referer = components.url?.absoluteString ?? referer
        }
        return ["User-Agent": NetworkProbe.userAgent, "Referer": referer]
    }
}
