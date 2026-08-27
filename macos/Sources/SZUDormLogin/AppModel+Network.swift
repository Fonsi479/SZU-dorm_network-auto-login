import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    func refreshStatus(allowAutoLogin: Bool = true) {
        guard !isRefreshing, !automation.isProbing else { return }
        launchAtLoginState = launchAtLogin.state
        autoLoginEnabled = campusProviderConfiguration.automaticEnabled
            && !coordinator.pauseStore.isPaused

        guard networkProbeEnabled else {
            clearNetworkStatus()
            return
        }

        if campusProductController != nil {
            refreshCampusProduct(allowAutoLogin: allowAutoLogin)
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
            let previousSessionState = lastNetworkStatus?.campusSessionState
            configuration = snapshot.configuration
            lastNetworkStatus = snapshot.status
            lastEnvironment = snapshot.environment
            apply(status: snapshot.status, environment: snapshot.environment)
            if snapshot.status.campusSessionState == .online {
                automation.recordAutoLoginSuccess()
            } else if Self.shouldAllowImmediateAutoLogin(
                previous: previousSessionState,
                current: snapshot.status.campusSessionState
            ) {
                // An online probe continuously keeps the ordinary retry
                // deadline in the future. Once the dorm portal is first seen
                // offline, bypass that stale success delay exactly once.
                automation.allowImmediateAutoLogin()
                logger.info("检测到宿舍门户会话断开，立即放行一次自动登录。")
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
        campusSnapshot = nil
        lastCampusLifecycle = nil
        statusText = "●  状态探测已关闭"
        statusTone = .neutral
        statusDetail = "周期性网关与联网检测已停止。"
    }

    func handleNetworkPathRestored() {
        guard networkProbeEnabled else { return }
        logger.info("检测到系统网络路径恢复，立即补做宿舍网络检查。")
        automation.cancelProbe()
        isRefreshing = false
        notifyCampusNetworkChangedAndRefresh()
    }

    func notifyCampusNetworkChangedAndRefresh() {
        guard let campusProductController else {
            refreshStatus()
            return
        }
        Task { [weak self] in
            await campusProductController.networkChanged()
            self?.refreshStatus()
        }
    }

    func refreshCampusProduct(allowAutoLogin: Bool) {
        guard let campusProductController,
              !isRefreshing,
              !automation.isProbing else { return }
        isRefreshing = true
        if campusSnapshot == nil {
            statusText = "●  正在检查网络…"
            statusTone = .checking
        }
        guard automation.startProbe(
            operation: { await campusProductController.refresh() },
            completion: { [weak self] result in
                self?.finishCampusProbe(result, allowAutoLogin: allowAutoLogin)
            }
        ) else {
            isRefreshing = false
            return
        }
    }

    func finishCampusProbe(
        _ result: Result<CampusProductSnapshot, Error>,
        allowAutoLogin: Bool
    ) {
        isRefreshing = false
        guard networkProbeEnabled else { return }
        switch result {
        case .failure(let error):
            statusText = "●  校园网状态待确认"
            statusTone = .failure
            statusDetail = error.localizedDescription
            logger.error("双 Provider 状态刷新失败：\(error.localizedDescription)")
        case .success(let snapshot):
            campusSnapshot = snapshot
            applyCampusSnapshot(snapshot)
            let lifecycle = selectedLifecycle(snapshot)
            if lifecycle == "online" {
                automation.recordAutoLoginSuccess()
            } else if lifecycle == "offline", lastCampusLifecycle != "offline" {
                automation.allowImmediateAutoLogin()
            }
            lastCampusLifecycle = lifecycle
            guard let campusProductController,
                  allowAutoLogin,
                  snapshot.automaticEnabled,
                  snapshot.category == .dorm || snapshot.category == .teaching,
                  lifecycle == "offline",
                  !automation.hasActiveOperation,
                  automation.consumeAutoLoginDeadline() else { return }
            guard automation.startAutoLogin(
                operation: {
                    Self.mapCampusResult(
                        await campusProductController.login(automatic: true)
                    )
                },
                completion: { [weak self] action in self?.finishAutoLogin(action) }
            ) else { return }
            isBusy = true
        }
    }

    func selectedLifecycle(_ snapshot: CampusProductSnapshot) -> String {
        switch snapshot.category {
        case .dorm: snapshot.dorm.lifecycle
        case .teaching: snapshot.teaching.lifecycle
        case .ambiguous, .nonCampus, .unknown: "idle"
        }
    }

    func applyCampusSnapshot(_ snapshot: CampusProductSnapshot) {
        environmentLabel = switch snapshot.category {
        case .dorm: "宿舍网络"
        case .teaching: "教学网络"
        case .ambiguous: "网络证据冲突"
        case .nonCampus: "非校园网络"
        case .unknown: "网络环境未知"
        }
        let lifecycle = selectedLifecycle(snapshot)
        switch snapshot.category {
        case .ambiguous:
            statusText = "●  校园网环境冲突"
            statusTone = .failure
        case .nonCampus:
            statusText = "●  当前不是校园网络"
            statusTone = .neutral
        case .unknown:
            statusText = "●  校园网状态待确认"
            statusTone = .warning
        case .dorm, .teaching:
            if lifecycle == "online" {
                statusText = "●  校园网在线"
                statusTone = .success
            } else if lifecycle == "offline" {
                statusText = "●  校园网离线"
                statusTone = .warning
            } else {
                statusText = "●  校园网状态待确认"
                statusTone = .warning
            }
        }
        statusDetail = [
            "Provider：\(snapshot.category.rawValue)",
            "会话：\(lifecycle)",
            snapshot.lastErrorCode.map { "错误码：\($0)" },
        ].compactMap { $0 }.joined(separator: "  ·  ")
        logger.info(
            "双 Provider 状态：category=\(snapshot.category.rawValue) lifecycle=\(lifecycle)"
        )
    }

    static func shouldAllowImmediateAutoLogin(
        previous: CampusSessionState?,
        current: CampusSessionState
    ) -> Bool {
        current == .offline && previous != .offline
    }
}
