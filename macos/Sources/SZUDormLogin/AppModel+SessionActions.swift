import SZUNetCore

@MainActor
extension AppModel {
    func loginNow() {
        guard !automation.hasActiveOperation else { return }
        automation.cancelProbe()
        isRefreshing = false

        if let campusProductController {
            guard automation.startManualOperation(
                operation: { Self.mapCampusResult(await campusProductController.login()) },
                completion: { [weak self] result in
                    self?.finishOperation(result, alwaysNotify: true)
                }
            ) else { return }
            isBusy = true
            return
        }
        let coordinator = coordinator
        guard automation.startManualOperation(
            operation: { await coordinator.loginNow() },
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

        if let campusProductController {
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
                        await campusProductController.logout(providerID: .dorm)
                    )
                },
                completion: { [weak self] result in
                    self?.finishOperation(result, alwaysNotify: true)
                }
            ) else { return }
            isBusy = true
            return
        }
        let coordinator = coordinator
        guard automation.startManualOperation(
            operation: { await coordinator.logout() },
            completion: { [weak self] result in
                guard let self else { return }
                self.autoLoginEnabled = !coordinator.pauseStore.isPaused
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
            detail: result.errorCode ?? "Provider：\(result.providerID.rawValue)",
            reason: result.errorCode ?? result.outcome.rawValue
        )
    }
}
