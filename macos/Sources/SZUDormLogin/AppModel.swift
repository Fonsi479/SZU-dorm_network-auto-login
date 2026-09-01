import Combine
import Foundation
import SZUNETEmbedded
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
    @Published var automationOwnershipSnapshot =
        CampusAutomationOwnershipSnapshot(
            currentOwner: nil,
            ownerRunning: false,
            canTransfer: true,
            isCurrentHostOwner: false
        )

    var onResult: ((LoginActionResult, Bool) -> Void)?
    var onConfigurationMigrated: ((URL) -> Void)?

    let coordinator: LoginCoordinator
    let logger: AppLogger
    let launchAtLogin: LaunchAtLoginController
    let automation: AppAutomationScheduler
    let automationOwnership: AppAutomationOwnership
    let embeddedRuntime: SZUNETEmbeddedRuntime?
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
        defaults: UserDefaults = .standard,
        automationOwnership: AppAutomationOwnership? = nil
    ) {
        self.logger = logger
        self.defaults = defaults
        self.coordinator = coordinator ?? LoginCoordinator(logger: logger)
        self.launchAtLogin = launchAtLogin
        self.automation = automation ?? AppAutomationScheduler()
        let paths = self.coordinator.configurationStore.paths
        self.automationOwnership = automationOwnership
            ?? AppAutomationOwnership(
                store: CampusAutomationStore(
                    fileURL: paths.automationFile,
                    lockFileURL: paths.automationLockFile,
                    legacyOwner: AppAutomationOwnership.legacyOwnerIfNeeded(paths: paths)
                )
            )
        automationOwnershipSnapshot = self.automationOwnership.snapshot
        _ = try? self.coordinator.configurationStore.load()
        embeddedRuntime = try? SZUNETEmbeddedRuntime.make(
            configuration: Self.makeEmbeddedConfiguration(paths: paths)
        )

        let sharedProbePreferences = self.automationOwnership.sharedProbePreferences()
        networkProbeEnabled = sharedProbePreferences.enabled
        networkProbeIntervalSeconds = sharedProbePreferences.intervalSeconds
        autoLoginEnabled = campusProviderConfiguration.automaticEnabled
            && !self.coordinator.pauseStore.isPaused
        launchAtLoginState = launchAtLogin.state
        loadConfiguration()
    }

    func start() {
        automationStarted = automationOwnership.start()
        automationOwnershipSnapshot = automationOwnership.snapshot
        if let embeddedRuntime {
            Task { @MainActor [weak self] in
                do {
                    try await embeddedRuntime.start(enabled: true)
                    let providers = try await embeddedRuntime.providerConfiguration()
                    self?.campusProviderConfiguration = providers
                    self?.autoLoginEnabled = providers.automaticEnabled
                        && !(self?.coordinator.pauseStore.isPaused ?? true)
                } catch {
                    guard let self else { return }
                    self.statusText = "●  校园网模块初始化失败"
                    self.statusTone = .failure
                    self.statusDetail = error.localizedDescription
                    self.logger.error("Embedded Runtime 初始化失败：\(error.localizedDescription)")
                    return
                }
                guard let self else { return }
                self.refreshAutomationOwnership()
                guard self.automationStarted else { return }
                guard self.networkProbeEnabled else {
                    self.clearNetworkStatus()
                    return
                }
                self.refreshStatus(allowAutoLogin: false)
                self.startProbeTimer(initialDelay: 5)
            }
            if !automationStarted {
                statusText = "●  自动化由其他客户端管理"
                statusTone = .neutral
                statusDetail = automationOwnershipDescription
            }
            return
        }
        guard automationStarted else {
            statusText = "●  自动化由其他客户端管理"
            statusTone = .neutral
            statusDetail = automationOwnershipDescription
            return
        }
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
        automationOwnership.stop()
        automationOwnershipSnapshot = automationOwnership.snapshot
        if let embeddedRuntime {
            Task { try? await embeddedRuntime.shutdown() }
        }
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
