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
    @Published var networkProbeIntervalSeconds = CampusAutomationPreferences.defaultProbeIntervalSeconds
    @Published var launchAtLoginState: LaunchAtLoginController.State = .disabled
    @Published var passwordSaved = false
    @Published var campusProviderConfiguration = CampusProductConfiguration.default
    @Published var campusSnapshot: CampusProductSnapshot?

    var onResult: ((LoginActionResult, Bool) -> Void)?
    var onConfigurationMigrated: ((URL) -> Void)?

    let coordinator: LoginCoordinator
    let logger: AppLogger
    let launchAtLogin: LaunchAtLoginController
    let automation: AppAutomationScheduler
    let campusSettingsStore: CampusProviderSettingsStore
    let campusProductController: CampusProductController?
    let defaults: UserDefaults

    var lastNetworkStatus: NetworkStatus?
    var lastEnvironment: NetworkEnvironment?
    var lastCampusLifecycle: String?
    var automationStarted = false

    init(
        coordinator: LoginCoordinator? = nil,
        logger: AppLogger = AppLogger(),
        launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
        automation: AppAutomationScheduler? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.logger = logger
        self.defaults = defaults
        self.coordinator = coordinator ?? LoginCoordinator(logger: logger)
        self.launchAtLogin = launchAtLogin
        self.automation = automation ?? AppAutomationScheduler()
        let paths = self.coordinator.configurationStore.paths
        campusSettingsStore = CampusProviderSettingsStore(
            fileURL: paths.campusProviderConfigurationFile
        )
        let legacyConfiguration = try? self.coordinator.configurationStore.load().configuration
        campusProviderConfiguration = (try? campusSettingsStore.load(
            legacyConfiguration: legacyConfiguration
        )) ?? .default
        campusProductController = try? CampusProductRuntime.make(paths: paths)

        networkProbeEnabled = CampusAutomationPreferences.networkProbeEnabled(in: defaults)
        networkProbeIntervalSeconds = CampusAutomationPreferences.probeIntervalSeconds(in: defaults)
        autoLoginEnabled = campusProviderConfiguration.automaticEnabled
            && !self.coordinator.pauseStore.isPaused
        launchAtLoginState = launchAtLogin.state
        loadConfiguration()
    }

    func start() {
        automationStarted = true
        guard networkProbeEnabled else {
            clearNetworkStatus()
            return
        }
        refreshStatus(allowAutoLogin: false)
        startProbeTimer(initialDelay: 5)
    }

    func stop() {
        automationStarted = false
        automation.stop()
        isRefreshing = false
        isBusy = false
    }

    func handleWake() {
        logger.info("检测到系统唤醒，立即补做联网状态检查。")
        automation.cancelProbe()
        isRefreshing = false
        notifyCampusNetworkChangedAndRefresh()
    }

    func startProbeTimer(initialDelay: TimeInterval) {
        guard automationStarted, networkProbeEnabled else { return }
        automation.startTimers(
            periodicInterval: TimeInterval(networkProbeIntervalSeconds),
            initialDelay: initialDelay
        ) { [weak self] in
            self?.refreshStatus()
        }
    }
}
