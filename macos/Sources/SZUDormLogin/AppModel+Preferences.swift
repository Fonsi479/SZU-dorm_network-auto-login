import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    func setAutoLoginEnabled(_ enabled: Bool) {
        if !enabled {
            automation.cancelAutoLogin()
            isBusy = automation.hasActiveOperation
        }
        do {
            if enabled {
                try coordinator.pauseStore.resume()
                automation.allowImmediateAutoLogin()
            } else {
                try coordinator.pauseStore.pause()
            }
            autoLoginEnabled = enabled
            onResult?(
                LoginActionResult(
                    outcome: .unchanged,
                    title: enabled ? "已恢复自动登录" : "已暂停自动登录",
                    detail: enabled ? "将继续按网络状态自动检查。" : coordinator.pauseStore.description(),
                    reason: enabled ? "resumed" : "paused"
                ),
                false
            )
            refreshStatus(allowAutoLogin: enabled)
        } catch {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "切换自动登录失败",
                    detail: error.localizedDescription,
                    reason: "pause_state_error"
                ),
                true
            )
            autoLoginEnabled = !coordinator.pauseStore.isPaused
        }
    }

    func setProviderEnabled(_ providerID: CampusProviderID, enabled: Bool) {
        var updated = campusProviderConfiguration
        if providerID == .dorm {
            updated.dorm.enabled = enabled
        } else {
            updated.teaching.enabled = enabled
        }
        do {
            try saveCampusProviderConfiguration(updated)
        } catch {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "Provider 设置保存失败",
                    detail: error.localizedDescription,
                    reason: "provider_settings_error"
                ),
                true
            )
        }
    }

    func setNetworkProbeEnabled(_ enabled: Bool) {
        networkProbeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "networkProbeEnabled")
        logger.info(enabled ? "已开启联网状态探测。" : "已关闭联网状态探测。")
        if enabled {
            refreshStatus()
        } else {
            automation.cancelProbe()
            isRefreshing = false
            clearNetworkStatus()
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            launchAtLoginState = launchAtLogin.state
            if launchAtLoginState == .requiresApproval {
                onResult?(
                    LoginActionResult(
                        outcome: .uncertain,
                        title: "需要在系统设置中批准",
                        detail: "已打开“登录项”，请允许 SZU Dorm Login 在登录时运行。",
                        reason: "requires_approval"
                    ),
                    false
                )
                launchAtLogin.openSystemSettings()
            } else {
                onResult?(
                    LoginActionResult(
                        outcome: .unchanged,
                        title: enabled ? "已启用登录时启动" : "已关闭登录时启动",
                        detail: "使用 macOS ServiceManagement 原生注册。",
                        reason: "launch_at_login_changed"
                    ),
                    false
                )
            }
        } catch {
            launchAtLoginState = launchAtLogin.state
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "无法修改登录时启动",
                    detail: error.localizedDescription,
                    reason: "launch_at_login_error"
                ),
                true
            )
        }
    }

    func resetPauseState() {
        do {
            try coordinator.pauseStore.resume()
            autoLoginEnabled = true
            automation.allowImmediateAutoLogin()
            onResult?(
                LoginActionResult(
                    outcome: .unchanged,
                    title: "暂停状态已重置",
                    detail: "自动登录已恢复。",
                    reason: "pause_reset"
                ),
                false
            )
            refreshStatus()
        } catch {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "重置暂停状态失败",
                    detail: error.localizedDescription,
                    reason: "pause_reset_failed"
                ),
                true
            )
        }
    }
}
