import Foundation

public struct SRunTransportResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public let finalURL: URL

    public init(statusCode: Int, body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.body = body
        self.finalURL = finalURL
    }
}

public protocol SRunTransporting: Sendable {
    func get(
        path: String,
        query: [String: String],
        baseURL: URL,
        sourceIP: String,
        timeout: TimeInterval
    ) async throws -> SRunTransportResponse
}

public final class SRunHTTPTransport: SRunTransporting, @unchecked Sendable {
    private let transport: HTTPTransporting

    public init(transport: HTTPTransporting = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func get(
        path: String,
        query: [String: String],
        baseURL: URL,
        sourceIP: String,
        timeout: TimeInterval
    ) async throws -> SRunTransportResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SZUNetError.network("ENV_PORTAL_IDENTITY_UNVERIFIED")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else { throw SZUNetError.network("ENV_PORTAL_IDENTITY_UNVERIFIED") }
        let response = try await transport.get(
            url,
            query: query,
            headers: ["Accept": "application/javascript, application/json"],
            timeout: timeout,
            sourceIP: sourceIP
        )
        guard response.finalURL.host?.lowercased() == baseURL.host?.lowercased() else {
            throw SZUNetError.network("NET_PROXY_INTERCEPTED")
        }
        return SRunTransportResponse(
            statusCode: response.statusCode,
            body: response.body,
            finalURL: response.finalURL
        )
    }
}

public actor TeachingSRunProvider: NetworkAuthProvider {
    public let providerID = CampusProviderID.teaching
    private let transport: SRunTransporting
    private let callbackFactory: @Sendable () -> String
    private let clockMilliseconds: @Sendable () -> UInt64
    private let allowedHosts: Set<String>

    public init(
        transport: SRunTransporting,
        allowedHosts: Set<String> = ["net.szu.edu.cn"],
        callbackFactory: @escaping @Sendable () -> String = {
            "_szu_cb_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        },
        clockMilliseconds: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.transport = transport
        self.allowedHosts = allowedHosts
        self.callbackFactory = callbackFactory
        self.clockMilliseconds = clockMilliseconds
    }

    public func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe {
        guard context.teachingPortalIdentityVerified, let portalURL = context.portalURL else {
            return unsupported("ENV_PORTAL_IDENTITY_UNVERIFIED")
        }
        guard context.sourceRouteBound, !context.sourceIP.isEmpty else {
            return unsupported("ENV_SOURCE_ROUTE_UNVERIFIED")
        }
        do {
            let configuration = try SRunPortalDiscovery.discover(
                entryURL: portalURL,
                pageHTML: context.portalHTML,
                sourceIP: context.sourceIP,
                allowedHosts: allowedHosts
            )
            return ProviderProbe(
                providerID: providerID,
                support: .supported,
                confidence: .verified,
                portalIdentity: configuration.portalURL.host ?? "",
                sourceInterface: context.sourceInterface,
                sourceIP: context.sourceIP,
                clientIP: configuration.clientIP,
                acid: configuration.acid,
                portalURL: configuration.portalURL,
                evidence: ["portal_identity_verified", "source_route_bound", "dynamic_acid"]
            )
        } catch let error as SRunPortalDiscoveryError {
            return ProviderProbe(
                providerID: providerID,
                support: error.code == "SRUN_CONFIG_CONFLICT" ? .ambiguous : .unsupported,
                confidence: .unknown,
                errorCode: error.code
            )
        } catch {
            return unsupported("ENV_AMBIGUOUS")
        }
    }

    public func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult {
        guard let baseURL = probe.portalURL, probe.isVerified else {
            return ProviderSessionResult(state: .blocked, errorCode: "ENV_PORTAL_IDENTITY_UNVERIFIED")
        }
        let callback = callbackFactory()
        do {
            let response = try await transport.get(
                path: "/cgi-bin/rad_user_info",
                query: ["callback": callback, "_": String(clockMilliseconds())],
                baseURL: baseURL,
                sourceIP: probe.sourceIP,
                timeout: 8
            )
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSessionResult(
                    state: .unknown,
                    errorCode: response.statusCode >= 500 ? "NET_TIMEOUT" : "SESSION_UNKNOWN",
                    retryable: response.statusCode >= 500
                )
            }
            let value = try SRunJSONP.decode(response.body, expectedCallback: callback)
            let error = string(value["error"])
            let onlineIP = string(value["online_ip"])
            if error == "ok", !onlineIP.isEmpty {
                let account = string(value["user_name"])
                return ProviderSessionResult(
                    state: .online,
                    accountMatch: account == username ? .matches : .differs,
                    clientIP: onlineIP,
                    product: string(value["products_name"]),
                    serverCode: error
                )
            }
            if error == "not_online_error" || (onlineIP.isEmpty && error.lowercased().contains("not_online")) {
                return ProviderSessionResult(state: .offline, serverCode: error)
            }
            return ProviderSessionResult(state: .unknown, serverCode: error, errorCode: "SESSION_UNKNOWN")
        } catch is SRunJSONPError {
            return ProviderSessionResult(state: .unknown, errorCode: "SRUN_JSONP_MALFORMED", retryable: true)
        } catch {
            return ProviderSessionResult(state: .unknown, errorCode: transportErrorCode(error), retryable: true)
        }
    }

    public func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult {
        guard let baseURL = probe.portalURL, probe.isVerified else {
            return .blocked(providerID, "ENV_SOURCE_ROUTE_UNVERIFIED")
        }
        guard !Task.isCancelled else { return cancelled() }
        let challengeCallback = callbackFactory()
        do {
            let challengeResponse = try await transport.get(
                path: "/cgi-bin/get_challenge",
                query: [
                    "callback": challengeCallback,
                    "username": username,
                    "ip": probe.clientIP,
                    "_": String(clockMilliseconds()),
                ],
                baseURL: baseURL,
                sourceIP: probe.sourceIP,
                timeout: 8
            )
            guard (200..<300).contains(challengeResponse.statusCode) else {
                return failed(
                    probe,
                    challengeResponse.statusCode >= 500 ? "NET_TIMEOUT" : "SRUN_CHALLENGE_FAILED",
                    retryable: challengeResponse.statusCode >= 500
                )
            }
            let challengeValue = try SRunJSONP.decode(
                challengeResponse.body,
                expectedCallback: challengeCallback
            )
            guard string(challengeValue["res"]) == "ok",
                  !string(challengeValue["challenge"]).isEmpty else {
                return failed(probe, "SRUN_CHALLENGE_FAILED", retryable: true)
            }
            let challengeIP = string(challengeValue["client_ip"])
            guard challengeIP.isEmpty || challengeIP == probe.clientIP else {
                return failed(probe, "SRUN_CONFIG_CONFLICT")
            }
            guard !Task.isCancelled else { return cancelled() }
            let challenge = string(challengeValue["challenge"])
            let fields = SRunCrypto.deriveLoginFields(
                username: username,
                password: credential.value,
                clientIP: probe.clientIP,
                acid: probe.acid,
                challenge: challenge
            )
            let loginCallback = callbackFactory()
            let loginResponse = try await transport.get(
                path: "/cgi-bin/srun_portal",
                query: [
                    "callback": loginCallback,
                    "action": "login",
                    "username": username,
                    "password": fields.passwordField,
                    "ac_id": probe.acid,
                    "ip": probe.clientIP,
                    "info": fields.infoField,
                    "chksum": fields.checksum,
                    "n": "200",
                    "type": "1",
                    "double_stack": "0",
                    "enc_ver": "srun_bx1",
                    "_": String(clockMilliseconds()),
                ],
                baseURL: baseURL,
                sourceIP: probe.sourceIP,
                timeout: 8
            )
            guard (200..<300).contains(loginResponse.statusCode) else {
                return failed(
                    probe,
                    loginResponse.statusCode >= 500 ? "NET_TIMEOUT" : "AUTH_NOT_CONFIRMED",
                    retryable: loginResponse.statusCode >= 500
                )
            }
            let ack = try SRunJSONP.decode(loginResponse.body, expectedCallback: loginCallback)
            let code = string(ack["error"])
            guard string(ack["res"]) == "ok" || code == "ip_already_online_error" else {
                return failed(probe, mapLoginError(code), retryable: false, serverCode: code)
            }
            guard !Task.isCancelled else { return cancelled() }
            let status = await sessionStatus(context, probe: probe, username: username)
            guard status.state == .online,
                  status.accountMatch == .matches,
                  status.clientIP == probe.clientIP else {
                return failed(probe, "AUTH_NOT_CONFIRMED", retryable: status.retryable, serverCode: code)
            }
            return ProviderAuthResult(
                outcome: code == "ip_already_online_error" ? .unchanged : .succeeded,
                providerID: providerID,
                sessionState: .online,
                accountMatch: .matches,
                clientIP: probe.clientIP,
                acid: probe.acid,
                serverCode: code
            )
        } catch is CancellationError {
            return cancelled()
        } catch is SRunJSONPError {
            return failed(probe, "SRUN_JSONP_MALFORMED", retryable: true)
        } catch {
            return failed(probe, transportErrorCode(error), retryable: true)
        }
    }

    public func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        .blocked(providerID, "SRUN_LOGOUT_DISABLED")
    }

    public func cancelPendingOperations(generation: UInt64) async {}

    private func unsupported(_ code: String) -> ProviderProbe {
        ProviderProbe(providerID: providerID, support: .unsupported, errorCode: code)
    }

    private func failed(
        _ probe: ProviderProbe,
        _ code: String,
        retryable: Bool = false,
        serverCode: String = ""
    ) -> ProviderAuthResult {
        ProviderAuthResult(
            outcome: .failed,
            providerID: providerID,
            clientIP: probe.clientIP,
            acid: probe.acid,
            errorCode: code,
            serverCode: serverCode,
            retryable: retryable
        )
    }

    private func cancelled() -> ProviderAuthResult {
        ProviderAuthResult(outcome: .cancelled, providerID: providerID, errorCode: "OPERATION_CANCELLED")
    }

    private func mapLoginError(_ code: String) -> String {
        switch code {
        case "E2531": "AUTH_BAD_PASSWORD"
        case "ip_already_online_error": "AUTH_IP_ALREADY_ONLINE"
        default: code.isEmpty ? "INTERNAL_ERROR" : code
        }
    }

    private func transportErrorCode(_ error: Error) -> String {
        let detail = error.localizedDescription.lowercased()
        if detail.contains("tls") { return "NET_TLS_FAILED" }
        if detail.contains("timeout") || detail.contains("超时") { return "NET_TIMEOUT" }
        return "NET_DNS_FAILED"
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}
