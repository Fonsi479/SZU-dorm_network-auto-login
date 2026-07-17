import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let model: AppModel
    let settingsWindow: SettingsWindowController
    let statusItem: NSStatusItem
    let menu = NSMenu()
    var cancellables = Set<AnyCancellable>()

    let statusMenuItem = NSMenuItem(title: "正在检查网络…", action: nil, keyEquivalent: "")
    let detailMenuItem = NSMenuItem(title: "正在初始化…", action: nil, keyEquivalent: "")
    let loginMenuItem = NSMenuItem(title: "立即登录", action: #selector(loginNow), keyEquivalent: "l")
    let logoutMenuItem = NSMenuItem(title: "退出当前账号", action: #selector(logout), keyEquivalent: "")
    let autoLoginMenuItem = ToggleMenuItem(title: "自动登录", action: #selector(toggleAutoLogin))
    let probeMenuItem = ToggleMenuItem(title: "联网状态探测", action: #selector(toggleProbe))
    let launchAtLoginMenuItem = ToggleMenuItem(
        title: "登录时启动",
        action: #selector(toggleLaunchAtLogin)
    )

    init(model: AppModel) {
        self.model = model
        settingsWindow = SettingsWindowController(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configureMenu()
        bindModel()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshStatus(allowAutoLogin: false)
    }

    func smokeTestIssues() -> [String] {
        var issues: [String] = []
        let titles = Set(menu.items.map(\.title))
        for required in [
            "立即登录", "退出当前账号", "自动登录", "联网状态探测",
            "账号与凭据", "诊断与维护", "登录时启动", "退出 SZU Dorm Login",
        ] where !titles.contains(required) {
            issues.append("缺少菜单项：\(required)")
        }
        let diagnostics = menu.items.first { $0.title == "诊断与维护" }?.submenu
        let diagnosticTitles = Set(diagnostics?.items.map(\.title) ?? [])
        for required in ["生成诊断报告", "打开配置文件", "打开日志目录", "运行原生自检"]
            where !diagnosticTitles.contains(required) {
            issues.append("诊断子菜单缺少：\(required)")
        }
        if statusItem.button == nil { issues.append("状态栏按钮没有创建") }
        return issues
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = ""
            button.image = NSImage(
                systemSymbolName: "network",
                accessibilityDescription: "SZU Dorm 网络状态"
            )
            button.imagePosition = .imageLeading
            button.toolTip = "深圳大学宿舍区校园网自动登录"
        }
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        detailMenuItem.indentationLevel = 1

        for item in [
            loginMenuItem,
            logoutMenuItem,
            autoLoginMenuItem,
            probeMenuItem,
            launchAtLoginMenuItem,
        ] {
            item.target = self
        }

        let accountItem = NSMenuItem(title: "账号与凭据", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu(title: "账号与凭据")
        accountMenu.addItem(actionItem("打开设置…", #selector(openSettings), key: ","))
        accountMenu.addItem(actionItem("修改账号…", #selector(changeUsername)))
        accountMenu.addItem(actionItem("修改密码…", #selector(changePassword)))
        accountItem.submenu = accountMenu

        let diagnosticsItem = NSMenuItem(title: "诊断与维护", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu(title: "诊断与维护")
        diagnosticsMenu.addItem(actionItem("生成诊断报告", #selector(generateDiagnosticReport)))
        diagnosticsMenu.addItem(actionItem("打开配置文件", #selector(openConfiguration)))
        diagnosticsMenu.addItem(actionItem("打开日志目录", #selector(openLogs)))
        diagnosticsMenu.addItem(.separator())
        diagnosticsMenu.addItem(actionItem("重置暂停状态", #selector(resetPause)))
        diagnosticsMenu.addItem(actionItem("运行原生自检", #selector(runSelfCheck)))
        diagnosticsItem.submenu = diagnosticsMenu

        [
            statusMenuItem,
            detailMenuItem,
            .separator(),
            loginMenuItem,
            logoutMenuItem,
            autoLoginMenuItem,
            .separator(),
            probeMenuItem,
            accountItem,
            diagnosticsItem,
            launchAtLoginMenuItem,
            .separator(),
            actionItem("退出 SZU Dorm Login", #selector(quit), key: "q"),
        ].forEach(menu.addItem)
    }

    private func bindModel() {
        model.$statusText
            .combineLatest(model.$statusTone)
            .receive(on: RunLoop.main)
            .sink { [weak self] text, tone in self?.updateStatus(text: text, tone: tone) }
            .store(in: &cancellables)

        model.$statusDetail
            .receive(on: RunLoop.main)
            .sink { [weak self] detail in self?.updateStatusDetail(detail) }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            model.$autoLoginEnabled,
            model.$networkProbeEnabled,
            model.$launchAtLoginState,
            model.$isBusy
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] autoLogin, probe, launchState, busy in
            self?.updateControls(
                autoLogin: autoLogin,
                probe: probe,
                launchState: launchState,
                busy: busy
            )
        }
        .store(in: &cancellables)

        model.onResult = { [weak self] result, showAlert in
            self?.present(result: result, showAlert: showAlert)
        }
    }

    private func updateControls(
        autoLogin: Bool,
        probe: Bool,
        launchState: LaunchAtLoginController.State,
        busy: Bool
    ) {
        autoLoginMenuItem.update(isOn: autoLogin)
        probeMenuItem.update(isOn: probe)
        switch launchState {
        case .enabled:
            launchAtLoginMenuItem.update(isOn: true)
        case .requiresApproval:
            launchAtLoginMenuItem.update(isOn: false, stateText: "待批准")
        case .disabled, .unavailable:
            launchAtLoginMenuItem.update(isOn: false)
        }
        loginMenuItem.isEnabled = !busy
        logoutMenuItem.isEnabled = !busy
        loginMenuItem.title = busy ? "正在处理…" : "立即登录"
    }

    private func updateStatus(text: String, tone: AppModel.StatusTone) {
        let color: NSColor
        switch tone {
        case .success: color = .systemGreen
        case .warning: color = .systemOrange
        case .failure: color = .systemRed
        case .checking: color = .systemBlue
        case .neutral: color = .secondaryLabelColor
        }
        statusMenuItem.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
        statusItem.button?.toolTip = "\(text)\n\(model.statusDetail)"
    }

    private func updateStatusDetail(_ detail: String) {
        detailMenuItem.attributedTitle = NSAttributedString(
            string: detail,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11),
            ]
        )
    }

    private func actionItem(
        _ title: String,
        _ selector: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }
}
