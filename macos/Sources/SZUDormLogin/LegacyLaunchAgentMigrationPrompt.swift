import AppKit

@MainActor
enum LegacyLaunchAgentMigrationPrompt {
    static func offerIfNeeded(model: AppModel?) {
        guard !LegacyLaunchAgentMigrator.installedAgents.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "检测到旧版 Python 自动登录服务"
        alert.informativeText = "为避免 Swift 应用和旧 Python LaunchAgent 重复登录，建议移除旧服务，并改用 macOS 原生“登录时启动”。配置和钥匙串密码不会被删除。"
        alert.addButton(withTitle: "迁移并移除旧服务")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try LegacyLaunchAgentMigrator.removeAll()
            model?.setLaunchAtLoginEnabled(true)
            let finished = NSAlert()
            finished.messageText = "旧版服务已移除"
            finished.informativeText = "现在由纯 Swift 菜单栏应用负责网络探测和自动登录。"
            finished.runModal()
        } catch {
            let failure = NSAlert()
            failure.messageText = "迁移未完全完成"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
        }
    }
}
