import Foundation

final class PortalLogoutTransaction {
    private struct CallResult {
        var acknowledgement: Bool?
        var inactive = false
        var noWebMode = false
    }

    private let configuration: AppConfiguration
    private let transport: HTTPTransporting
    private let logger: AppLogger
    private let endpoints: PortalEndpoints
    private let reader: PortalSessionReader

    init(configuration: AppConfiguration, transport: HTTPTransporting, logger: AppLogger) {
        self.configuration = configuration
        self.transport = transport
        self.logger = logger
        self.endpoints = PortalEndpoints(configuration: configuration)
        self.reader = PortalSessionReader(
            configuration: configuration,
            transport: transport,
            logger: logger
        )
    }

    func execute(username: String, sourceIP: String) async -> LogoutResult {
        let before = await reader.snapshot(username: username, sourceIP: sourceIP)
        switch before.fact.state {
        case .offline:
            return LogoutResult(status: .success, reason: "already_logged_out")
        case .unknown:
            return LogoutResult(status: .unknown, reason: "session_state_unknown")
        case .online:
            break
        }
        guard !before.fact.account.isEmpty, !before.fact.ip.isEmpty else {
            return LogoutResult(status: .failed, reason: "terminal_ip_not_found")
        }

        let jsVersion = configuration.auth.logoutJSVersion
        let terminal = before.terminal(jsVersion: jsVersion)
        logger.info(
            "开始门户注销事务：unbind=\(before.runtime.shouldUnbindMAC) "
                + "mac=\(before.fact.mac.isEmpty ? "missing" : "server")"
        )

        if before.runtime.shouldUnbindMAC,
           !before.fact.mac.isEmpty,
           let unbindURL = endpoints.unbindURL {
            let account = before.fact.account
            let query = PortalRequestBuilder.unbind(
                configuration: configuration,
                account: account,
                fact: before.fact,
                jsVersion: jsVersion,
                stripISPSuffix: before.runtime.ispUnbindSuffix
            )
            let result = await call(unbindURL, query: query, sourceIP: before.fact.ip)
            logger.info("门户 MAC 解绑应答：\(ackLabel(result.acknowledgement))")
            if result.acknowledgement == true {
                let state = await verifiedState(expected: before.fact)
                if state == .offline {
                    return LogoutResult(status: .success, reason: "unbind_verified")
                }
            }
            // The deployed page intentionally falls through when unbind reports
            // `mac不存在`; it is not a terminal failure.
        }

        var lastState = PortalSessionState.unknown
        var noWebMode = false

        if before.runtime.usesPortalLogout,
           let portalLogoutURL = endpoints.configuredOrPortalLogoutURL {
            let result = await call(
                portalLogoutURL,
                query: PortalRequestBuilder.portalLogout(
                    configuration: configuration,
                    terminal: terminal,
                    runtime: before.runtime
                ),
                sourceIP: before.fact.ip
            )
            logger.info("/eportal/portal/logout 应答：\(ackLabel(result.acknowledgement))")
            lastState = await verifiedState(expected: before.fact)
            if lastState == .offline {
                return LogoutResult(status: .success, reason: "portal_logout_verified")
            }
        } else if let drcomLogoutURL = endpoints.drcom("logout") {
            // Official page code calls util._jsonp with data={}; callback is the
            // transport-level JSONP parameter, not portal/logout's drcom/123 body.
            let result = await call(
                drcomLogoutURL,
                query: ["callback": logoutCallback],
                sourceIP: before.fact.ip
            )
            noWebMode = result.noWebMode
            logger.info("/drcom/logout 应答：\(ackLabel(result.acknowledgement))")
            lastState = await verifiedState(expected: before.fact)
            if lastState == .offline {
                return LogoutResult(status: .success, reason: "drcom_logout_verified")
            }
        }

        // Portal API and the page-declared ACSetting endpoint are compatibility
        // fallbacks only. An ACK from either is never accepted without re-reading
        // chkstatus / the exact online_list identity.
        let candidates = fallbackCandidates(page: before.page).filter {
            !before.runtime.usesPortalLogout || $0 != endpoints.configuredOrPortalLogoutURL
        }
        if noWebMode || lastState == .online || lastState == .unknown {
            for candidate in candidates {
                let usesPortalBody = candidate.path.hasSuffix("/portal/logout")
                let query = usesPortalBody
                    ? PortalRequestBuilder.portalLogout(
                        configuration: configuration,
                        terminal: terminal,
                        runtime: before.runtime
                    )
                    : [:]
                let result = await call(candidate, query: query, sourceIP: before.fact.ip)
                logger.info(
                    "门户注销 fallback endpoint=\(candidate.path) ack="
                        + ackLabel(result.acknowledgement)
                )
                lastState = await verifiedState(expected: before.fact)
                if lastState == .offline {
                    return LogoutResult(status: .success, reason: "portal_logout_verified")
                }
            }
        }

        if lastState == .online {
            return LogoutResult(status: .failed, reason: "logout_not_confirmed")
        }
        return LogoutResult(status: .unknown, reason: "session_verification_unavailable")
    }

    private var logoutCallback: String {
        configuration.auth.logoutCallback.isEmpty ? "dr1004" : configuration.auth.logoutCallback
    }

    private func fallbackCandidates(page: PortalPageContext) -> [URL] {
        var seen = Set<String>()
        return [endpoints.configuredOrPortalLogoutURL, page.declaredLogoutURL]
            .compactMap { $0 }
            .filter { seen.insert($0.absoluteString).inserted }
    }

    private func verifiedState(expected: PortalSessionFact) async -> PortalSessionState {
        var last = PortalSessionState.unknown
        for delay in [UInt64(0), 350_000_000, 900_000_000] {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) } catch { return last }
            }
            let fact = await reader.sessionFact(username: expected.account, sourceIP: expected.ip)
            last = fact.state
            if last == .offline { return .offline }
        }
        return last
    }

    private func call(_ url: URL, query: [String: String], sourceIP: String) async -> CallResult {
        do {
            let response = try await transport.get(
                url,
                query: query,
                headers: endpoints.headers(),
                timeout: TimeInterval(configuration.auth.timeoutSeconds),
                sourceIP: sourceIP.isEmpty ? nil : sourceIP
            )
            guard (200..<300).contains(response.statusCode) else { return CallResult() }
            let text = response.bodyText
            let parsed = PortalCodec.parseJSONP(text)
            return CallResult(
                acknowledgement: PortalResponseClassifier.success(parsed),
                inactive: PortalResponseClassifier.inactiveLogout(parsed),
                noWebMode: text.lowercased().contains("no webmode")
            )
        } catch {
            logger.warning(
                "门户注销请求异常 endpoint=\(url.path) reason="
                    + String(error.localizedDescription.prefix(120))
            )
            return CallResult()
        }
    }

    private func ackLabel(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "accepted"
        case .some(false): return "rejected"
        case .none: return "unknown"
        }
    }
}
