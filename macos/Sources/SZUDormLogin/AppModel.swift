import Combine
import Foundation
import SZUNetCore

@MainActor
final class AppModel: ObservableObject {
    typealias ProbeSnapshot = (
        configuration: AppConfiguration,
        status: NetworkStatus,
        environment: NetworkEnvironment
    )

    enum StatusTone: Equatable {
        case checking
        case success
        case warning
        case failure
        case neutral
    }

    @Published var configuration = AppConfiguration.default
    @Published var statusText = "●  正在检查网络…"
    @Published var statusTone: StatusTone = .checking
    @Published var environmentLabel = "网络环境未知"
    @Published var statusDetail = "正在初始化原生 Swift 网络核心。"
    @Published var isBusy = false
    @Published var isRefreshing = false
    @Published var autoLoginEnabled = true
    @Published var networkProbeEnabled = true
    @Published var launchAtLoginState: LaunchAtLoginController.State = .disabled
    @Published var passwordSaved = false

    var onResult: ((LoginActionResult, Bool) -> Void)?
    var onConfigurationMigrated: ((URL) -> Void)?

    let coordinator: LoginCoordinator
    let logger: AppLogger
    let launchAtLogin: LaunchAtLoginController
    let automation: AppAutomationScheduler

    var lastNetworkStatus: NetworkStatus?
    var lastEnvironment: NetworkEnvironment?

    init(
        coordinator: LoginCoordinator? = nil,
        logger: AppLogger = AppLogger(),
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        automation: AppAutomationScheduler? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.logger = logger
        self.coordinator = coordinator ?? LoginCoordinator(logger: logger)
        self.launchAtLogin = launchAtLogin
        self.automation = automation ?? AppAutomationScheduler()

        networkProbeEnabled = defaults.object(forKey: "networkProbeEnabled") == nil
            ? true
            : defaults.bool(forKey: "networkProbeEnabled")
        autoLoginEnabled = !self.coordinator.pauseStore.isPaused
        launchAtLoginState = launchAtLogin.state
        loadConfiguration()
    }

    func start() {
        refreshStatus(allowAutoLogin: false)
        automation.startTimers(periodicInterval: 30, initialDelay: 5) { [weak self] in
            self?.refreshStatus()
        }
    }

    func stop() {
        automation.stop()
        isRefreshing = false
        isBusy = false
    }

    func handleWake() {
        logger.info("检测到系统唤醒，立即补做联网状态检查。")
        automation.cancelProbe()
        isRefreshing = false
        refreshStatus()
    }
}
