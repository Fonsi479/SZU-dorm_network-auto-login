import SZUNetCore
import SZUNETEmbedded

@MainActor
extension AppModel {
    func loginNow() {
        guard !automation.hasActiveOperation else { return }
        automation.cancelProbe()
        isRefreshing = false

        guard let embeddedRuntime else {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "无法登录校园网",
                    detail: "Embedded Runtime 初始化失败；未读取凭据或发送认证请求。",
                    reason: "embedded_runtime_unavailable"
                ),
                true
            )
            return
        }
        guard automation.startManualOperation(
            operation: { Self.mapCampusResult(await embeddedRuntime.login()) },
            completion: { [weak self] result in
                self?.finishOperation(result, alwaysNotify: true)
            }
        ) else {
            return
        }
        isBusy = true
    }

    func logout() {
        guard !automation.hasManualOperation else { return }

        // Manual logout owns authentication until the portal confirms offline.
        // Invalidating both lanes prevents an older online probe or automatic
        // login result from being published after the user's explicit action.
        automation.cancelProbe()
        automation.cancelAutoLogin()
        isRefreshing = false
        isBusy = automation.hasActiveOperation

        guard let embeddedRuntime else {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "无法退出校园网",
                    detail: "Embedded Runtime 初始化失败；未发送退出请求。",
                    reason: "embedded_runtime_unavailable"
                ),
                true
            )
            return
        }
        guard campusSnapshot?.category == .dorm else {
            onResult?(
                LoginActionResult(
                    outcome: .unchanged,
                    title: "当前网络不支持退出",
                    detail: "Teaching SRun 与未确认环境的退出操作已禁用。",
                    reason: "logout_disabled"
                ),
                false
            )
            return
        }
        guard automation.startManualOperation(
            operation: {
                Self.mapCampusResult(
                    await embeddedRuntime.logout(providerID: .dorm)
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.finishOperation(result, alwaysNotify: true)
            }
        ) else {
            return
        }
        isBusy = true
    }

    static func mapCampusResult(_ result: ProviderAuthResult) -> LoginActionResult {
        let outcome: LoginActionOutcome = switch result.outcome {
        case .succeeded: result.sessionState == .offline ? .loggedOut : .authenticated
        case .unchanged: .unchanged
        case .failed, .blocked: .failed
        case .cancelled: .uncertain
        }
        return LoginActionResult(
            outcome: outcome,
            title: outcome == .authenticated ? "校园网登录成功" : outcome == .loggedOut ? "已退出校园网" : "校园网操作完成",
            detail: Self.actionDetail(for: result),
            reason: result.errorCode ?? result.outcome.rawValue
        )
    }

    private static func actionDetail(for result: ProviderAuthResult) -> String {
        switch result.errorCode {
        case "AUTH_DEVICE_LIMIT":
            return "账号已有 3 台设备在线，普通登录已阻止以避免挤下其他设备。若确需切换，请在完整设置页面确认，或显式运行 --force-login。"
        case let code? where !code.isEmpty:
            return code
        default:
            return "Provider：\(result.providerID.rawValue)"
        }
    }
}
