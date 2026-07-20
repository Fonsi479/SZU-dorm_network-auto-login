import AppKit
import SZUNetCore

@MainActor
extension MenuBarController {
    @objc func loginNow() {
        if !model.passwordSaved {
            guard promptForPassword(title: "首次登录需要密码") else { return }
        }
        model.loginNow()
    }

    @objc func logout() {
        model.logout()
    }

    @objc func toggleAutoLogin() {
        model.setAutoLoginEnabled(!model.autoLoginEnabled)
    }

    @objc func toggleProbe() {
        model.setNetworkProbeEnabled(!model.networkProbeEnabled)
    }

    @objc func toggleLaunchAtLogin() {
        let enable: Bool
        switch model.launchAtLoginState {
        case .enabled: enable = false
        case .disabled, .requiresApproval, .unavailable: enable = true
        }
        model.setLaunchAtLoginEnabled(enable)
    }

    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        settingsWindow.show()
    }

    @objc func changeUsername() {
        let alert = NSAlert()
        alert.messageText = "修改校园网账号"
        alert.informativeText = "密码仍保存在 macOS 钥匙串中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(
            string: model.configuration.user.username == UserConfiguration.placeholder
                ? ""
                : model.configuration.user.username
        )
        field.placeholderString = "学号或校园网账号"
        field.setAccessibilityLabel("校园网账号")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.saveUsername(field.stringValue)
            present(
                result: LoginActionResult(
                    outcome: .unchanged,
                    title: "账号已保存",
                    detail: "配置已更新。"
                ),
                showAlert: false
            )
        } catch {
            showError(title: "修改账号失败", detail: error.localizedDescription)
        }
    }

    @objc func changePassword() {
        _ = promptForPassword(title: "修改校园网密码")
    }

    func promptForPassword(title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "密码将直接保存到 macOS 钥匙串，不会写入配置或日志。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "校园网密码"
        field.setAccessibilityLabel("校园网密码")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try model.savePassword(field.stringValue)
            present(
                result: LoginActionResult(
                    outcome: .unchanged,
                    title: "密码已保存",
                    detail: "已写入 macOS 钥匙串。"
                ),
                showAlert: false
            )
            return true
        } catch {
            showError(title: "保存密码失败", detail: error.localizedDescription)
            return false
        }
    }
}
