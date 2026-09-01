import Foundation
import SZUNETEmbedded
import SZUNetCore

private struct CampusRefreshResult {
    let snapshot: CampusProductSnapshot
    let recovery: ProviderAuthResult?
}

@MainActor
extension AppModel {
    func refreshStatus(allowAutoLogin: Bool = true) {
        guard !isRefreshing, !automation.isProbing else { return }
        // Timer, wake and network-path refreshes are automation work. A
        // non-owner may still trigger an explicit menu/settings refresh by
        // passing `allowAutoLogin: false`.
        if allowAutoLogin, !verifyAutomationOwner() { return }
        launchAtLoginState = launchAtLogin.state
        autoLoginEnabled = campusProviderConfiguration.automaticEnabled
            && !coordinator.pauseStore.isPaused

        guard networkProbeEnabled else {
            clearNetworkStatus()
            return
        }

        guard embeddedRuntime != nil else {
            statusText = "●  校园网模块不可用"
            statusTone = .failure
            statusDetail = "Embedded Runtime 初始化失败；未执行状态探测或认证。"
            return
        }
        refreshCampusProduct(allowAutoLogin: allowAutoLogin)
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
        guard verifyAutomationOwner() else { return }
        guard let embeddedRuntime else {
            statusText = "●  校园网模块不可用"
            statusTone = .failure
            statusDetail = "Embedded Runtime 初始化失败；未执行网络变化处理。"
            return
        }
        Task { [weak self] in
            await embeddedRuntime.networkChanged()
            self?.refreshStatus()
        }
    }

    func refreshCampusProduct(allowAutoLogin: Bool) {
        guard let embeddedRuntime,
              !isRefreshing,
              !automation.isProbing else { return }
        if allowAutoLogin, !verifyAutomationOwner() { return }
        isRefreshing = true
        if campusSnapshot == nil {
            statusText = "●  正在检查网络…"
            statusTone = .checking
        }
        guard automation.startProbe(
            operation: {
                let recovery = allowAutoLogin
                    ? await embeddedRuntime.recoverAutomatically()
                    : nil
                return CampusRefreshResult(
                    snapshot: await embeddedRuntime.refreshProduct(),
                    recovery: recovery
                )
            },
            completion: { [weak self] result in
                self?.finishCampusProbe(result, allowAutoLogin: allowAutoLogin)
            }
        ) else {
            isRefreshing = false
            return
        }
    }

    private func finishCampusProbe(
        _ result: Result<CampusRefreshResult, Error>,
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
        case .success(let refresh):
            let snapshot = refresh.snapshot
            campusSnapshot = snapshot
            applyCampusSnapshot(snapshot)
            let lifecycle = selectedLifecycle(snapshot)
            if lifecycle == "online" {
                automation.recordAutoLoginSuccess()
            } else if lifecycle == "offline", lastCampusLifecycle != "offline" {
                automation.allowImmediateAutoLogin()
            }
            lastCampusLifecycle = lifecycle
            guard allowAutoLogin, let recovery = refresh.recovery else { return }
            switch recovery.outcome {
            case .succeeded:
                automation.recordAutoLoginSuccess()
                onResult?(Self.mapCampusResult(recovery), false)
            case .unchanged:
                automation.recordAutoLoginSuccess()
            case .failed:
                automation.recordAutoLoginFailure()
                onResult?(Self.mapCampusResult(recovery), true)
            case .cancelled:
                automation.recordAutoLoginFailure()
            case .blocked:
                // Core owns the authentication backoff and fatal/dynamic
                // safety gates.  A blocked recovery remains visible in the
                // compact status without producing a notification every 30s.
                break
            }
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
            Self.onlineDeviceSummary(snapshot),
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

    /// Device identifiers are intentionally never exposed.  Only the
    /// server-reported aggregate is shown in the compact status surface.
    private static func onlineDeviceSummary(_ snapshot: CampusProductSnapshot) -> String? {
        guard let count = snapshot.onlineDeviceCount else { return nil }
        return "在线设备：\(count)/\(snapshot.onlineDeviceLimit ?? 3)"
    }
}
