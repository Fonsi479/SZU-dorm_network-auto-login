enum LoginActionMapper {
    static func login(_ result: LoginResult) -> LoginActionResult {
        let label = LoginCoordinator.reasonLabel(result.reason)
        switch result.status {
        case .success:
            return LoginActionResult(
                outcome: .authenticated,
                title: "登录成功",
                detail: "门户会话已确认在线。",
                reason: result.reason
            )
        case .failed:
            return LoginActionResult(
                outcome: .failed,
                title: "登录失败：\(label)",
                detail: "详情已写入脱敏日志。",
                reason: result.reason
            )
        case .unknown:
            return LoginActionResult(
                outcome: .uncertain,
                title: "登录结果不确定：\(label)",
                detail: "门户没有确认当前账号会话在线。",
                reason: result.reason
            )
        }
    }

    static func logout(_ result: LogoutResult, pauseDescription: String) -> LoginActionResult {
        if result.reason == "already_logged_out" {
            return LoginActionResult(
                outcome: .loggedOut,
                title: "当前已是离线状态",
                detail: pauseDescription,
                reason: result.reason
            )
        }
        switch result.status {
        case .success:
            return LoginActionResult(
                outcome: .loggedOut,
                title: "已退出校园网账号",
                detail: "门户会话已确认离线；\(pauseDescription)。",
                reason: "logout_confirmed"
            )
        case .failed:
            return LoginActionResult(
                outcome: .failed,
                title: "退出失败",
                detail: LoginCoordinator.logoutReasonLabel(result.reason),
                reason: result.reason
            )
        case .unknown:
            return LoginActionResult(
                outcome: .uncertain,
                title: "退出结果不确定",
                detail: LoginCoordinator.logoutReasonLabel(result.reason),
                reason: result.reason
            )
        }
    }
}
