import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    func refreshStatus(allowAutoLogin: Bool = true) {
        guard !isRefreshing, !automation.isProbing else { return }
        launchAtLoginState = launchAtLogin.state
        autoLoginEnabled = !coordinator.pauseStore.isPaused

        guard networkProbeEnabled else {
            clearNetworkStatus()
            return
        }

        isRefreshing = true
        if lastNetworkStatus == nil {
            statusText = "●  正在检查网络…"
            statusTone = .checking
        }
        let coordinator = coordinator
        if !automation.startProbe(
            operation: { try await coordinator.probe() },
            completion: { [weak self] result in
                self?.finishProbe(result, allowAutoLogin: allowAutoLogin)
            }
        ) {
            isRefreshing = false
        }
    }

    func finishProbe(
        _ result: Result<ProbeSnapshot, Error>,
        allowAutoLogin: Bool
    ) {
        isRefreshing = false
        guard networkProbeEnabled else { return }

        switch result {
        case .success(let snapshot):
            configuration = snapshot.configuration
            lastNetworkStatus = snapshot.status
            lastEnvironment = snapshot.environment
            apply(status: snapshot.status, environment: snapshot.environment)
            updatePasswordState()
            if snapshot.status.campusSessionState == .online {
                automation.recordAutoLoginSuccess()
            }
            if allowAutoLogin {
                maybeAutoLogin(status: snapshot.status, environment: snapshot.environment)
            }
        case .failure(let error):
            statusText = "●  配置需要检查"
            statusTone = .failure
            statusDetail = error.localizedDescription
            logger.error("状态刷新失败：\(error.localizedDescription)")
        }
    }

    func apply(status: NetworkStatus, environment: NetworkEnvironment) {
        let presentation = AppStatusPresentation.make(
            status: status,
            environment: environment,
            autoLoginEnabled: autoLoginEnabled
        )
        environmentLabel = environment.label
        statusText = presentation.text
        statusTone = presentation.tone
        statusDetail = presentation.detail
        logger.info(presentation.logMessage)
    }

    func maybeAutoLogin(status: NetworkStatus, environment: NetworkEnvironment) {
        guard networkProbeEnabled,
              !automation.hasActiveOperation,
              autoLoginEnabled,
              !coordinator.pauseStore.isPaused,
              status.campusSessionState == .offline,
              environment.autoLoginAvailable,
              automation.consumeAutoLoginDeadline() else {
            return
        }

        let coordinator = coordinator
        guard automation.startAutoLogin(
            operation: { await coordinator.checkAndLogin() },
            completion: { [weak self] result in self?.finishAutoLogin(result) }
        ) else {
            return
        }
        isBusy = true
    }

    func finishAutoLogin(_ result: LoginActionResult) {
        switch result.outcome {
        case .authenticated:
            automation.recordAutoLoginSuccess()
        case .failed, .uncertain:
            automation.recordAutoLoginFailure()
        case .unchanged:
            if result.reason == "session_already_online" {
                automation.recordAutoLoginSuccess()
            }
        case .loggedOut:
            break
        }
        let shouldNotify = result.outcome == .failed
            || result.outcome == .uncertain
            || result.outcome == .authenticated
        finishOperation(result, alwaysNotify: shouldNotify)
    }

    func finishOperation(_ result: LoginActionResult, alwaysNotify: Bool) {
        isBusy = automation.hasActiveOperation
        if alwaysNotify {
            onResult?(result, result.outcome == .failed || result.outcome == .uncertain)
        }
        refreshStatus(allowAutoLogin: false)
    }

    func clearNetworkStatus() {
        lastNetworkStatus = nil
        lastEnvironment = nil
        statusText = "●  状态探测已关闭"
        statusTone = .neutral
        statusDetail = "周期性网关与联网检测已停止。"
    }
}
