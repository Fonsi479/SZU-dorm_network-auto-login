import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    func setAutoLoginEnabled(_ enabled: Bool) {
        guard requireAutomationOwnership(for: enabled ? "恢复自动登录" : "暂停自动登录") else {
            return
        }
        guard let embeddedRuntime else {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "切换自动登录失败",
                    detail: "Embedded Runtime 初始化失败。",
                    reason: "embedded_runtime_unavailable"
                ),
                true
            )
            return
        }
        if !enabled {
            automation.cancelAutoLogin()
            isBusy = automation.hasActiveOperation
        }
        let previousConfiguration = campusProviderConfiguration
        var updated = previousConfiguration
        updated.automaticEnabled = enabled
        campusProviderConfiguration = updated
        Task { [weak self] in
            do {
                try await embeddedRuntime.updateProviderConfiguration(updated)
                if enabled {
                    try await embeddedRuntime.resumeAutomation()
                } else {
                    try await embeddedRuntime.pauseAutomation()
                }
                guard let self else { return }
                self.autoLoginEnabled = enabled
                if enabled { self.automation.allowImmediateAutoLogin() }
                self.onResult?(
                    LoginActionResult(
                        outcome: .unchanged,
                        title: enabled ? "已恢复自动登录" : "已暂停自动登录",
                        detail: enabled
                            ? "将继续按网络状态自动检查。"
                            : self.coordinator.pauseStore.description(),
                        reason: enabled ? "resumed" : "paused"
                    ),
                    false
                )
                self.refreshStatus(allowAutoLogin: enabled)
            } catch {
                if self?.campusProviderConfiguration == updated {
                    self?.campusProviderConfiguration = previousConfiguration
                    self?.autoLoginEnabled = previousConfiguration.automaticEnabled
                        && !(self?.coordinator.pauseStore.isPaused ?? true)
                }
                self?.onResult?(
                    LoginActionResult(
                        outcome: .failed,
                        title: "切换自动登录失败",
                        detail: error.localizedDescription,
                        reason: "pause_state_error"
                    ),
                    true
                )
            }
        }
    }

    func setProviderEnabled(_ providerID: CampusProviderID, enabled: Bool) {
        guard requireAutomationOwnership(for: "修改 Provider 设置") else { return }
        guard embeddedRuntime != nil else {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "Provider 设置保存失败",
                    detail: "Embedded Runtime 初始化失败。",
                    reason: "embedded_runtime_unavailable"
                ),
                true
            )
            return
        }
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
        guard requireAutomationOwnership(for: enabled ? "开启联网探测" : "关闭联网探测") else {
            return
        }
        do {
            let shared = try automationOwnership.setSharedProbePreferences(
                enabled: enabled,
                intervalSeconds: networkProbeIntervalSeconds
            )
            networkProbeEnabled = shared.enabled
            // Keep the old defaults keys in sync for clients that have not yet
            // adopted automation.json. They are never authoritative here.
            _ = CampusAutomationPreferences.setNetworkProbeEnabled(shared.enabled, in: defaults)
            logger.info(shared.enabled ? "已开启联网状态探测。" : "已关闭联网状态探测。")
            if shared.enabled {
                startProbeTimer(initialDelay: TimeInterval(networkProbeIntervalSeconds))
                refreshStatus(allowAutoLogin: false)
            } else {
                automation.suspendTimers()
                automation.cancelProbe()
                automation.cancelAutoLogin()
                isRefreshing = false
                isBusy = automation.hasActiveOperation
                clearNetworkStatus()
            }
        } catch {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "切换联网探测失败",
                    detail: error.localizedDescription,
                    reason: "automation_store_error"
                ),
                true
            )
        }
    }

    func setNetworkProbeIntervalSeconds(_ seconds: Int) {
        let normalized = CampusAutomationPreferences.normalizedProbeInterval(seconds)
        guard networkProbeIntervalSeconds != normalized else { return }
        guard requireAutomationOwnership(for: "修改联网探测间隔") else { return }
        do {
            let shared = try automationOwnership.setSharedProbePreferences(
                enabled: networkProbeEnabled,
                intervalSeconds: normalized
            )
            networkProbeIntervalSeconds = shared.intervalSeconds
            _ = CampusAutomationPreferences.setProbeIntervalSeconds(
                shared.intervalSeconds,
                in: defaults
            )
            logger.info("联网状态探测间隔已设为 \(shared.intervalSeconds) 秒。")
            if networkProbeEnabled {
                startProbeTimer(initialDelay: TimeInterval(shared.intervalSeconds))
            }
        } catch {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "修改联网探测间隔失败",
                    detail: error.localizedDescription,
                    reason: "automation_store_error"
                ),
                true
            )
        }
    }

    func reloadAutomationPreferences() {
        let shared = automationOwnership.sharedProbePreferences()
        let enabled = shared.enabled
        let interval = shared.intervalSeconds
        let enabledChanged = enabled != networkProbeEnabled
        let intervalChanged = interval != networkProbeIntervalSeconds

        if enabledChanged {
            if verifyAutomationOwner() {
                setNetworkProbeEnabled(enabled)
            } else {
                networkProbeEnabled = enabled
            }
        } else if intervalChanged, enabled {
            networkProbeIntervalSeconds = interval
            if isAutomationOwner {
                startProbeTimer(initialDelay: TimeInterval(interval))
            }
        } else {
            networkProbeIntervalSeconds = interval
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
        guard requireAutomationOwnership(for: "重置自动登录暂停状态") else { return }
        guard let embeddedRuntime else {
            onResult?(
                LoginActionResult(
                    outcome: .failed,
                    title: "重置暂停状态失败",
                    detail: "Embedded Runtime 初始化失败。",
                    reason: "embedded_runtime_unavailable"
                ),
                true
            )
            return
        }
        let previousConfiguration = campusProviderConfiguration
        var updated = previousConfiguration
        updated.automaticEnabled = true
        campusProviderConfiguration = updated
        Task { [weak self] in
            do {
                try await embeddedRuntime.updateProviderConfiguration(updated)
                try await embeddedRuntime.resumeAutomation()
                guard let self else { return }
                self.autoLoginEnabled = true
                self.automation.allowImmediateAutoLogin()
                self.onResult?(
                    LoginActionResult(
                        outcome: .unchanged,
                        title: "暂停状态已重置",
                        detail: "自动登录已恢复。",
                        reason: "pause_reset"
                    ),
                    false
                )
                self.refreshStatus()
            } catch {
                if self?.campusProviderConfiguration == updated {
                    self?.campusProviderConfiguration = previousConfiguration
                }
                self?.onResult?(
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
}
