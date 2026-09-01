import Foundation

public final class LoginCoordinator {
    public let configurationStore: ConfigurationStore
    public let credentials: CredentialStoring
    public let pauseStore: PauseStore
    public let networkProbe: NetworkProbing
    public let logger: AppLogger

    private let clientFactory: (AppConfiguration) -> DrCOMServicing
    private let operationLock: AuthenticationOperationLock

    public init(
        configurationStore: ConfigurationStore = ConfigurationStore(),
        credentials: CredentialStoring = KeychainStore(),
        pauseStore: PauseStore = PauseStore(),
        networkProbe: NetworkProbing? = nil,
        logger: AppLogger = AppLogger(),
        clientFactory: ((AppConfiguration) -> DrCOMServicing)? = nil,
        logoutVerificationDelays: [UInt64] = [0]
    ) {
        self.configurationStore = configurationStore
        self.credentials = credentials
        self.pauseStore = pauseStore
        self.logger = logger
        self.networkProbe = networkProbe ?? NetworkProbe(logger: logger)
        self.clientFactory = clientFactory ?? { DrCOMClient(configuration: $0, logger: logger) }
        self.operationLock = AuthenticationOperationLock(
            url: configurationStore.paths.authenticationLockFile
        )
        _ = logoutVerificationDelays // Source compatibility with 2.0 migration builds.
    }

    public func currentConfiguration() throws -> AppConfiguration {
        try configurationStore.load().configuration
    }

    public func currentPassword(configuration: AppConfiguration) throws -> String? {
        try CredentialResolver(store: credentials).password(for: configuration)
    }

    public func savePassword(_ password: String, configuration: AppConfiguration) throws {
        try credentials.setPassword(
            password,
            service: configuration.security.keychainService,
            account: configuration.keychainAccount
        )
    }

    public func probe() async throws -> (AppConfiguration, NetworkStatus, NetworkEnvironment) {
        let configuration = try currentConfiguration()
        var status = networkProbe.probeGateway(configuration: configuration)
        let username = configuration.user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.gatewayReachable,
           !status.sourceIP.isEmpty,
           !username.isEmpty,
           username != UserConfiguration.placeholder {
            let online = await clientFactory(configuration).isSessionOnline(
                username: username,
                sourceIP: status.sourceIP
            )
            status.campusSessionState = online.map { $0 ? .online : .offline } ?? .unknown
        }
        if status.campusSessionState == .online {
            status = await networkProbe.probeInternet(
                configuration: configuration,
                status: status
            )
        } else {
            status.campusInternetOK = false
            status.internetPortalRedirect = false
            status.internetReason = status.campusSessionState == .offline
                ? "skipped_session_offline"
                : "skipped_session_unknown"
        }
        let environment = networkProbe.classify(configuration: configuration, status: status)
        return (configuration, status, environment)
    }

    public func sessionStatus() async throws -> (
        AppConfiguration,
        NetworkStatus,
        NetworkEnvironment
    ) {
        let configuration = try currentConfiguration()
        var status = networkProbe.probeGateway(configuration: configuration)
        let username = configuration.user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.gatewayReachable,
           !status.sourceIP.isEmpty,
           !username.isEmpty,
           username != UserConfiguration.placeholder {
            let online = await clientFactory(configuration).isSessionOnline(
                username: username,
                sourceIP: status.sourceIP
            )
            status.campusSessionState = online.map { $0 ? .online : .offline } ?? .unknown
        }
        status.internetReason = "not_probed"
        let environment = networkProbe.classify(configuration: configuration, status: status)
        return (configuration, status, environment)
    }

    public func loginNow() async -> LoginActionResult {
        guard let lease = try? operationLock.tryAcquire() else {
            return operationInProgress("登录")
        }
        defer { lease.release() }

        do {
            let configuration = try currentConfiguration().validatedForLogin()
            let status = networkProbe.probeGateway(configuration: configuration)
            guard status.gatewayReachable else {
                return unchanged("非宿舍网络", "宿舍区网关不可达，本轮未读取或发送账号密码。", "gateway_unreachable")
            }
            let environment = networkProbe.classify(configuration: configuration, status: status)
            guard environment.autoLoginAvailable, !status.sourceIP.isEmpty else {
                return unchanged("未验证的网络", "源路由未经验证，本轮未读取或发送账号密码。", "unverified_source_ip")
            }
            try Task.checkCancellation()
            let client = clientFactory(configuration)
            let session = await client.sessionStatus(
                username: configuration.user.username,
                sourceIP: status.sourceIP
            )
            if session.state == .online {
                return unchanged("校园网会话已在线", "无需重复登录。", "session_already_online")
            }
            guard session.state == .offline,
                  session.errorCode != "SESSION_UNKNOWN" else {
                return unchanged("会话状态无法确认", "为避免误发凭据，本轮未登录。", "session_unverified")
            }
            if Self.isAtDormDeviceLimit(session) {
                return unchanged(
                    "校园网在线设备已达上限",
                    "检测到账号已有 3 台设备在线，本轮未读取或发送账号密码。",
                    "AUTH_DEVICE_LIMIT"
                )
            }
            try Task.checkCancellation()
            guard let password = try currentPassword(configuration: configuration), !password.isEmpty else {
                return missingPassword(auto: false)
            }
            try Task.checkCancellation()
            logger.info("用户发起立即登录。")
            let result = await client.login(
                username: configuration.user.username,
                password: password,
                knownSourceIP: status.sourceIP
            )
            if Task.isCancelled { return cancelled() }
            return LoginActionMapper.login(result)
        } catch is CancellationError {
            return cancelled()
        } catch {
            logger.error("立即登录失败：\(error.localizedDescription)")
            return configurationFailure(title: "无法登录", error: error)
        }
    }

    /// Explicit manual replacement for the legacy standalone Dorm app.  This
    /// method is never called by `checkAndLogin`; it can only bypass the
    /// confirmed Dorm 3/3 device-limit gate after the caller's confirmation.
    public func forceLoginNow() async -> LoginActionResult {
        guard let lease = try? operationLock.tryAcquire() else {
            return operationInProgress("强制切换登录")
        }
        defer { lease.release() }

        do {
            let configuration = try currentConfiguration().validatedForLogin()
            let status = networkProbe.probeGateway(configuration: configuration)
            guard status.gatewayReachable else {
                return unchanged(
                    "非宿舍网络",
                    "宿舍区网关不可达，本轮未读取或发送账号密码。",
                    "gateway_unreachable"
                )
            }
            let environment = networkProbe.classify(configuration: configuration, status: status)
            guard environment.isDormNetwork,
                  environment.autoLoginAvailable,
                  !status.sourceIP.isEmpty else {
                return unchanged(
                    "未验证的宿舍网络",
                    "仅允许在已验证的宿舍区网络执行强制切换，本轮未读取或发送账号密码。",
                    "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED"
                )
            }
            try Task.checkCancellation()
            let client = clientFactory(configuration)
            let session = await client.sessionStatus(
                username: configuration.user.username,
                sourceIP: status.sourceIP
            )
            if session.state == .online {
                return unchanged("校园网会话已在线", "无需重复登录。", "session_already_online")
            }
            guard session.state == .offline,
                  session.errorCode != "SESSION_UNKNOWN" else {
                return unchanged(
                    "会话状态无法确认",
                    "为避免误发凭据，本轮未执行强制切换。",
                    "session_unverified"
                )
            }
            guard Self.isConfirmedDormDeviceLimit(session) else {
                return unchanged(
                    "未达到设备上限",
                    "仅在确认账号已有 3 台设备在线时允许强制切换。",
                    "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED"
                )
            }
            try Task.checkCancellation()
            guard let password = try currentPassword(configuration: configuration), !password.isEmpty else {
                return missingPassword(auto: false)
            }
            try Task.checkCancellation()
            logger.info("用户确认强制切换 Dorm 会话。")
            let result = await client.login(
                username: configuration.user.username,
                password: password,
                knownSourceIP: status.sourceIP
            )
            if Task.isCancelled { return cancelled() }
            return LoginActionMapper.login(result)
        } catch is CancellationError {
            return cancelled()
        } catch {
            logger.error("强制切换登录失败：\(error.localizedDescription)")
            return configurationFailure(title: "强制切换失败", error: error)
        }
    }

    public func checkAndLogin() async -> LoginActionResult {
        guard !pauseStore.isPaused else { return paused() }
        guard let lease = try? operationLock.tryAcquire() else {
            return operationInProgress("自动登录")
        }
        defer { lease.release() }

        do {
            let configuration = try currentConfiguration().validatedForLogin()
            let status = networkProbe.probeGateway(configuration: configuration)
            guard status.gatewayReachable else {
                return unchanged("非宿舍网络", "宿舍区网关不可达，本轮未发送账号密码。", "gateway_unreachable")
            }
            let environment = networkProbe.classify(configuration: configuration, status: status)
            guard environment.autoLoginAvailable else {
                return unchanged("未验证的网络", "源 IP 不在配置的校园网段，本轮未发送账号密码。", "unverified_source_ip")
            }
            try Task.checkCancellation()
            guard !pauseStore.isPaused else { return paused() }

            let client = clientFactory(configuration)
            let session = await client.sessionStatus(
                username: configuration.user.username,
                sourceIP: status.sourceIP
            )
            if session.state == .online {
                return unchanged("校园网会话已在线", "无需重复登录。", "session_already_online")
            }
            guard session.state == .offline,
                  session.errorCode != "SESSION_UNKNOWN" else {
                return unchanged("会话状态无法确认", "为避免误发凭据，本轮未自动登录。", "session_unverified")
            }
            if Self.isAtDormDeviceLimit(session) {
                return unchanged(
                    "校园网在线设备已达上限",
                    "检测到账号已有 3 台设备在线，本轮未读取或发送账号密码。",
                    "AUTH_DEVICE_LIMIT"
                )
            }
            try Task.checkCancellation()
            guard !pauseStore.isPaused else { return paused() }
            guard let password = try currentPassword(configuration: configuration), !password.isEmpty else {
                return missingPassword(auto: true)
            }
            try Task.checkCancellation()
            guard !pauseStore.isPaused else { return paused() }

            logger.info("门户已确认离线，开始受控自动登录。")
            let result = await client.login(
                username: configuration.user.username,
                password: password,
                knownSourceIP: status.sourceIP
            )
            if Task.isCancelled { return cancelled() }
            return LoginActionMapper.login(result)
        } catch is CancellationError {
            return cancelled()
        } catch {
            logger.error("自动登录检查失败：\(error.localizedDescription)")
            return configurationFailure(title: "自动登录失败", error: error)
        }
    }

    public func logout() async -> LoginActionResult {
        do {
            try pauseStore.pause()
        } catch {
            return LoginActionResult(
                outcome: .failed,
                title: "未执行退出",
                detail: "无法先暂停自动登录：\(error.localizedDescription)",
                reason: "pause_failed"
            )
        }
        guard let lease = try? operationLock.tryAcquire() else {
            return operationInProgress("退出")
        }
        defer { lease.release() }

        do {
            let configuration = try currentConfiguration().validatedForPortalAction()
            let status = networkProbe.probeGateway(configuration: configuration)
            let result = await clientFactory(configuration).logout(
                username: configuration.user.username,
                knownSourceIP: status.sourceIP
            )
            return LoginActionMapper.logout(result, pauseDescription: pauseStore.description())
        } catch {
            return configurationFailure(title: "退出失败", error: error)
        }
    }

    public static func reasonLabel(_ reason: String) -> String {
        let labels = [
            "password_missing": "密码缺失", "password_error": "密码错误",
            "gateway_unreachable": "网关不可达", "session_verified": "会话已确认",
            "login_not_confirmed": "登录未确认", "session_verification_unavailable": "会话验证不可用",
            "portal_interface_changed": "门户接口变化", "server_response_uncertain": "服务器响应不确定",
            "server_failed": "门户返回失败", "request_exception": "网络请求异常",
            "AUTH_DEVICE_LIMIT": "在线设备已达上限",
            "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED": "不允许强制切换设备",
            "cancelled": "操作已取消",
        ]
        if reason.hasPrefix("http_status_") {
            return "HTTP 状态码 " + reason.replacingOccurrences(of: "http_status_", with: "")
        }
        return labels[reason] ?? (reason.isEmpty ? "未知原因" : reason)
    }

    static func logoutReasonLabel(_ reason: String) -> String {
        let labels = [
            "logout_url_not_configured": "无法确定退出接口。",
            "terminal_ip_not_found": "无法确定当前终端 IP。",
            "session_state_unknown": "无法读取当前门户会话。",
            "logout_not_confirmed": "门户仍报告当前账号在线。",
            "session_verification_unavailable": "退出请求完成，但会话验证不可用。",
        ]
        return labels[reason] ?? reasonLabel(reason)
    }

    private func paused() -> LoginActionResult {
        unchanged("已暂停自动登录", pauseStore.description(), "paused")
    }

    private func cancelled() -> LoginActionResult {
        unchanged("操作已取消", "未继续发送校园网请求。", "cancelled")
    }

    private func operationInProgress(_ action: String) -> LoginActionResult {
        unchanged("已有认证操作正在进行", "本次\(action)未并发执行。", "operation_in_progress")
    }

    private func missingPassword(auto: Bool) -> LoginActionResult {
        LoginActionResult(
            outcome: .failed,
            title: auto ? "自动登录失败：密码缺失" : "登录失败：密码缺失",
            detail: "请先把密码保存到 macOS 钥匙串。",
            reason: "password_missing"
        )
    }

    private func unchanged(_ title: String, _ detail: String, _ reason: String) -> LoginActionResult {
        LoginActionResult(outcome: .unchanged, title: title, detail: detail, reason: reason)
    }

    private func configurationFailure(title: String, error: Error) -> LoginActionResult {
        LoginActionResult(
            outcome: .failed,
            title: title,
            detail: error.localizedDescription,
            reason: "configuration_error"
        )
    }

    private static func isAtDormDeviceLimit(_ session: ProviderSessionResult) -> Bool {
        return isConfirmedDormDeviceLimit(session)
            || session.errorCode == "AUTH_DEVICE_LIMIT"
    }

    private static func isConfirmedDormDeviceLimit(_ session: ProviderSessionResult) -> Bool {
        let limit = session.onlineDeviceLimit ?? CampusOnlineDevicePolicy.dormLimit
        return limit == CampusOnlineDevicePolicy.dormLimit
            && session.onlineDeviceCount.map { $0 >= limit } == true
    }
}
