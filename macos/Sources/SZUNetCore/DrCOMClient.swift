import Foundation

public final class DrCOMClient {
    public static let userAgent = NetworkProbe.userAgent

    private let configuration: AppConfiguration
    private let transport: HTTPTransporting
    private let logger: AppLogger

    public init(
        configuration: AppConfiguration,
        transport: HTTPTransporting = PortalHTTPTransport(),
        logger: AppLogger = AppLogger()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.logger = logger
    }

    public func buildLoginParameters(
        username: String,
        password: String,
        sourceIP: String = "",
        macAddress: String = ""
    ) -> [String: String] {
        PortalRequestBuilder.login(
            configuration: configuration,
            username: username,
            password: password,
            sourceIP: sourceIP,
            macAddress: macAddress
        )
    }

    public func login(
        username: String,
        password: String,
        knownSourceIP: String = ""
    ) async -> LoginResult {
        let endpoints = PortalEndpoints(configuration: configuration)
        guard let loginURL = endpoints.loginURL else {
            return LoginResult(status: .failed, reason: "portal_interface_changed")
        }
        let timeout = TimeInterval(configuration.auth.timeoutSeconds)
        let sourceIP = knownSourceIP.isEmpty
            ? resolveSourceIP(for: loginURL, timeout: timeout)
            : knownSourceIP
        if sourceIP.isEmpty { logger.warning("宿舍区 Dr.COM 登录未能确定源 IP。") }

        do {
            let response = try await transport.get(
                loginURL,
                query: buildLoginParameters(
                    username: username,
                    password: password,
                    sourceIP: sourceIP
                ),
                headers: endpoints.headers(refererURL: loginURL),
                timeout: timeout,
                sourceIP: sourceIP.isEmpty ? nil : sourceIP
            )
            logger.info("宿舍区 Dr.COM 登录 HTTP 状态码=\(response.statusCode)")
            logger.info(
                "宿舍区 Dr.COM 登录响应前 200 字=\(String(response.bodyText.prefix(200)))",
                password: password
            )
            if response.statusCode >= 500 {
                return LoginResult(
                    status: .unknown,
                    reason: "server_response_uncertain",
                    httpStatus: response.statusCode,
                    sourceIP: sourceIP
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                return LoginResult(
                    status: .failed,
                    reason: "portal_interface_changed",
                    httpStatus: response.statusCode,
                    sourceIP: sourceIP
                )
            }

            let parsed = PortalCodec.parseJSONP(response.bodyText)
            switch PortalResponseClassifier.success(parsed) {
            case .some(true):
                let verified = await PortalSessionReader(
                    configuration: configuration,
                    transport: transport,
                    logger: logger
                ).verifyLogin(username: username, sourceIP: sourceIP)
                if verified == true {
                    return LoginResult(
                        status: .success,
                        reason: "session_verified",
                        httpStatus: response.statusCode,
                        sourceIP: sourceIP
                    )
                }
                return LoginResult(
                    status: .unknown,
                    reason: verified == false ? "login_not_confirmed" : "session_verification_unavailable",
                    httpStatus: response.statusCode,
                    sourceIP: sourceIP
                )
            case .some(false):
                let reason = PortalResponseClassifier.containsPasswordError(
                    PortalResponseClassifier.responseText(parsed)
                ) ? "password_error" : "server_failed"
                return LoginResult(
                    status: .failed,
                    reason: reason,
                    httpStatus: response.statusCode,
                    sourceIP: sourceIP
                )
            case .none:
                return LoginResult(
                    status: .unknown,
                    reason: "portal_interface_changed",
                    httpStatus: response.statusCode,
                    sourceIP: sourceIP
                )
            }
        } catch {
            logger.error("宿舍区 Dr.COM 登录请求异常：\(Self.safeError(error))", password: password)
            let detail = error.localizedDescription.lowercased()
            let reason = detail.contains("timeout") || detail.contains("connect")
                ? "gateway_unreachable" : "request_exception"
            return LoginResult(status: .failed, reason: reason, sourceIP: sourceIP)
        }
    }

    public func logout(
        username: String,
        knownSourceIP: String = ""
    ) async -> LogoutResult {
        let endpoints = PortalEndpoints(configuration: configuration)
        guard let target = endpoints.loginURL ?? endpoints.pageURL else {
            return LogoutResult(status: .failed, reason: "logout_url_not_configured")
        }
        let timeout = TimeInterval(configuration.auth.timeoutSeconds)
        let sourceIP = knownSourceIP.isEmpty
            ? resolveSourceIP(for: target, timeout: timeout)
            : knownSourceIP
        return await PortalLogoutTransaction(
            configuration: configuration,
            transport: transport,
            logger: logger
        ).execute(username: username, sourceIP: sourceIP)
    }

    public func isSessionOnline(username: String, sourceIP: String) async -> Bool? {
        let fact = await PortalSessionReader(
            configuration: configuration,
            transport: transport,
            logger: logger
        ).sessionFact(username: username, sourceIP: sourceIP)
        switch fact.state {
        case .online: return fact.matches(username: username, sourceIP: sourceIP)
        case .offline: return false
        case .unknown: return nil
        }
    }

    private func resolveSourceIP(for url: URL, timeout: TimeInterval) -> String {
        guard let host = url.host else { return "" }
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))
        return (try? SocketHTTPClient.sourceAddress(host: host, port: port, timeout: timeout)) ?? ""
    }

    private static func safeError(_ error: Error) -> String {
        String(error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }
}
