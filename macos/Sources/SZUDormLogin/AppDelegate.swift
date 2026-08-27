import AppKit
import SZUNetCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let openSettingsOnLaunch: Bool
    private var model: AppModel?
    private var menuBarController: MenuBarController?
    private var networkPathObserver: NetworkPathObserver?
    private var wakeObserver: NSObjectProtocol?

    init(openSettingsOnLaunch: Bool = false) {
        self.openSettingsOnLaunch = openSettingsOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserNotificationPresenter.requestAuthorization()
        let model = AppModel(logger: AppLogger())
        self.model = model
        menuBarController = MenuBarController(model: model)

        model.onConfigurationMigrated = { source in
            let alert = NSAlert()
            alert.messageText = "旧版配置已迁移"
            alert.informativeText = "已从 \(source.path) 导入账号和网络设置。密码继续使用同名 macOS 钥匙串项目。"
            alert.alertStyle = .informational
            alert.runModal()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak model] _ in
            Task { @MainActor in model?.handleWake() }
        }

        let networkPathObserver = NetworkPathObserver()
        self.networkPathObserver = networkPathObserver
        networkPathObserver.start { [weak model] isAvailable in
            if isAvailable {
                model?.handleNetworkPathRestored()
            }
        }

        model.start()
        if openSettingsOnLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.menuBarController?.openSettings()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak model] in
            LegacyLaunchAgentMigrationPrompt.offerIfNeeded(model: model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkPathObserver?.stop()
        model?.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: {
            $0.scheme?.lowercased() == "szunet"
                && $0.host?.lowercased() == "settings"
        }) {
            menuBarController?.openSettings()
        }
        if urls.contains(where: {
            $0.scheme?.lowercased() == "szunet"
                && $0.host?.lowercased() == "automation"
                && $0.path.lowercased() == "/reload"
        }) {
            model?.reloadAutomationPreferences()
        }
    }
}
