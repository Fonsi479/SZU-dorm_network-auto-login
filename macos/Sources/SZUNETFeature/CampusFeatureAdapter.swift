import Foundation
// SZUNetCore intentionally remains in Swift 5 language mode during the first
// integration release. This actor is the single serialized compatibility
// boundary; only immutable Sendable DTOs leave it. The adapter tests exercise
// cancellation, feature gating, manual logout suppression and automatic-login
// eligibility while the upstream package keeps its own state-machine tests.
@preconcurrency import SZUNetCore

public struct SZUNETFeaturePaths: Sendable {
    public var unifiedConfigurationDirectory: URL

    public init(unifiedConfigurationDirectory: URL) {
        self.unifiedConfigurationDirectory = unifiedConfigurationDirectory
    }

    public static var live: SZUNETFeaturePaths {
        SZUNETFeaturePaths(
            unifiedConfigurationDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/CodexQuotaBar/Campus",
                    isDirectory: true
                )
        )
    }

    public var unifiedConfigurationURL: URL {
        unifiedConfigurationDirectory.appendingPathComponent("config.json")
    }
}

public enum SZUNETActionOutcome: String, Codable, Equatable, Sendable {
    case authenticated
    case loggedOut
    case unchanged
    case failed
    case uncertain
    case cancelled
}

public struct SZUNETActionResult: Codable, Equatable, Sendable {
    public var outcome: SZUNETActionOutcome
    public var title: String
    public var detail: String
    public var reason: String

    public init(
        outcome: SZUNETActionOutcome,
        title: String,
        detail: String = "",
        reason: String = ""
    ) {
        self.outcome = outcome
        self.title = title
        self.detail = detail
        self.reason = reason
    }

    public var isSuccess: Bool {
        switch outcome {
        case .authenticated, .loggedOut, .unchanged:
            true
        case .failed, .uncertain, .cancelled:
            false
        }
    }
}

public struct SZUNETConfigurationSummary: Codable, Equatable, Sendable {
    public var username: String
    public var portalHost: String
    public var sourceNetworkCount: Int

    public init(username: String, portalHost: String, sourceNetworkCount: Int) {
        self.username = username
        self.portalHost = portalHost
        self.sourceNetworkCount = max(sourceNetworkCount, 0)
    }
}

public struct SZUNETProbeResult: Equatable, Sendable {
    public var environment: SZUNETEnvironment
    public var portal: SZUNETPortalState
    public var internet: SZUNETReachabilityState
    public var environmentLabel: String
    public var environmentReason: String
    public var gatewayReason: String
    public var internetReason: String
    public var autoLoginPaused: Bool
    public var networkCategory: SZUNETNetworkCategory?
    public var providers: [SZUNETProviderStatus]?

    public init(
        environment: SZUNETEnvironment,
        portal: SZUNETPortalState,
        internet: SZUNETReachabilityState,
        environmentLabel: String,
        environmentReason: String,
        gatewayReason: String,
        internetReason: String,
        autoLoginPaused: Bool,
        networkCategory: SZUNETNetworkCategory? = nil,
        providers: [SZUNETProviderStatus]? = nil
    ) {
        self.environment = environment
        self.portal = portal
        self.internet = internet
        self.environmentLabel = environmentLabel
        self.environmentReason = environmentReason
        self.gatewayReason = gatewayReason
        self.internetReason = internetReason
        self.autoLoginPaused = autoLoginPaused
        self.networkCategory = networkCategory
        self.providers = providers
    }
}

public struct SZUNETSnapshot: Equatable, Sendable {
    public var status: SZUNETStatus
    public var configuration: SZUNETConfigurationSummary?
    public var environmentLabel: String
    public var detail: String
    public var manualLogoutSuppressed: Bool
    public var nextAutomaticAttemptAt: Date?
    public var lastAction: SZUNETActionResult?

    public init(
        status: SZUNETStatus = SZUNETStatus(),
        configuration: SZUNETConfigurationSummary? = nil,
        environmentLabel: String = "未检查",
        detail: String = "校园网模块已关闭，不会探测网络或读取校园网密码。",
        manualLogoutSuppressed: Bool = false,
        nextAutomaticAttemptAt: Date? = nil,
        lastAction: SZUNETActionResult? = nil
    ) {
        self.status = status
        self.configuration = configuration
        self.environmentLabel = environmentLabel
        self.detail = detail
        self.manualLogoutSuppressed = manualLogoutSuppressed
        self.nextAutomaticAttemptAt = nextAutomaticAttemptAt
        self.lastAction = lastAction
    }
}

public protocol SZUNETCoordinatorDriving: Sendable {
    func probe() async throws -> SZUNETProbeResult
    func manualLogin() async -> SZUNETActionResult
    func automaticLogin() async -> SZUNETActionResult
    func manualLogout() async -> SZUNETActionResult
    func setAutoLoginEnabled(_ enabled: Bool) async throws
    func configurationSummary() async throws -> SZUNETConfigurationSummary
    func saveCredentials(username: String, password: String?) async throws
}

public actor SZUNETCoordinatorDriver: SZUNETCoordinatorDriving {
    private let coordinator: LoginCoordinator
    private let productController: CampusProductController?

    public init(paths: SZUNETFeaturePaths = .live) {
        if FileManager.default.fileExists(atPath: paths.unifiedConfigurationURL.path) {
            let legacyPaths = AppPaths.standard
            let unifiedPaths = AppPaths(
                applicationSupportDirectory: paths.unifiedConfigurationDirectory,
                logDirectory: legacyPaths.logDirectory
            )
            coordinator = LoginCoordinator(
                configurationStore: ConfigurationStore(paths: unifiedPaths)
            )
            productController = try? CampusProductRuntime.make(paths: unifiedPaths)
        } else {
            coordinator = LoginCoordinator()
            productController = try? CampusProductRuntime.make()
        }
    }

    public func probe() async throws -> SZUNETProbeResult {
        if let productController {
            let snapshot = await productController.refresh()
            let lifecycle: String = switch snapshot.category {
            case .dorm: snapshot.dorm.lifecycle
            case .teaching: snapshot.teaching.lifecycle
            case .ambiguous, .nonCampus, .unknown: "unknown"
            }
            let portal: SZUNETPortalState = switch lifecycle {
            case "online": .authenticated
            case "offline": .unauthenticated
            default: .unknown
            }
            let environment: SZUNETEnvironment = switch snapshot.category {
            case .dorm, .teaching: .eligible
            case .nonCampus: .ineligible
            case .ambiguous, .unknown: .unknown
            }
            return SZUNETProbeResult(
                environment: environment,
                portal: portal,
                internet: .unknown,
                environmentLabel: snapshot.category.rawValue,
                environmentReason: snapshot.lastErrorCode ?? snapshot.category.rawValue,
                gatewayReason: "managed_by_campus_product_controller",
                internetReason: "not_probed",
                autoLoginPaused: coordinator.pauseStore.isPaused,
                networkCategory: Self.category(from: snapshot.category),
                providers: Self.providers(from: snapshot)
            )
        }
        let (_, status, environment) = try await coordinator.probe()
        let internet: SZUNETReachabilityState
        if status.campusInternetOK {
            internet = .reachable
        } else if status.internetReason == "not_probed" || status.internetReason.hasPrefix("skipped_") {
            internet = .unknown
        } else {
            internet = .unreachable
        }
        return SZUNETProbeResult(
            environment: Self.environment(from: environment),
            portal: Self.portal(from: status.campusSessionState),
            internet: internet,
            environmentLabel: environment.label,
            environmentReason: environment.reason,
            gatewayReason: status.gatewayReason,
            internetReason: status.internetReason,
            autoLoginPaused: coordinator.pauseStore.isPaused
        )
    }

    public func manualLogin() async -> SZUNETActionResult {
        if let productController { return Self.map(await productController.login()) }
        return Self.map(await coordinator.loginNow())
    }

    public func automaticLogin() async -> SZUNETActionResult {
        if let productController { return Self.map(await productController.login(automatic: true)) }
        return Self.map(await coordinator.checkAndLogin())
    }

    public func manualLogout() async -> SZUNETActionResult {
        if let productController {
            let snapshot = await productController.currentSnapshot()
            guard snapshot.category == .dorm else {
                return SZUNETActionResult(
                    outcome: .unchanged,
                    title: "当前 Provider 不支持退出",
                    reason: "logout_disabled"
                )
            }
            return Self.map(await productController.logout(providerID: .dorm))
        }
        return Self.map(await coordinator.logout())
    }

    public func setAutoLoginEnabled(_ enabled: Bool) async throws {
        if enabled {
            try coordinator.pauseStore.resume()
        } else {
            try coordinator.pauseStore.pause()
        }
    }

    public func configurationSummary() async throws -> SZUNETConfigurationSummary {
        let configuration = try coordinator.currentConfiguration()
        let username = configuration.user.username == UserConfiguration.placeholder
            ? ""
            : configuration.user.username
        return SZUNETConfigurationSummary(
            username: username,
            portalHost: URL(string: configuration.auth.loginURL)?.host ?? "未配置",
            sourceNetworkCount: configuration.network.campusSourceNetworks.count
        )
    }

    public func saveCredentials(username: String, password: String?) async throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw SZUNetError.configuration("校园网账号不能为空。")
        }
        let configuration = try coordinator.configurationStore.updateUsername(trimmedUsername)
        if let password, !password.isEmpty {
            try coordinator.savePassword(password, configuration: configuration)
        }
    }

    private static func map(_ result: LoginActionResult) -> SZUNETActionResult {
        let outcome: SZUNETActionOutcome = switch result.outcome {
        case .authenticated: .authenticated
        case .loggedOut: .loggedOut
        case .unchanged: .unchanged
        case .failed: .failed
        case .uncertain: .uncertain
        }
        return SZUNETActionResult(
            outcome: outcome,
            title: result.title,
            detail: result.detail,
            reason: result.reason
        )
    }

    private static func map(_ result: ProviderAuthResult) -> SZUNETActionResult {
        let outcome: SZUNETActionOutcome = switch result.outcome {
        case .succeeded: result.sessionState == .offline ? .loggedOut : .authenticated
        case .unchanged: .unchanged
        case .failed, .blocked: .failed
        case .cancelled: .cancelled
        }
        return SZUNETActionResult(
            outcome: outcome,
            title: outcome == .authenticated ? "校园网登录成功" : outcome == .loggedOut ? "已退出校园网" : "校园网操作完成",
            reason: result.errorCode ?? result.outcome.rawValue
        )
    }

    private static func category(from value: CampusNetworkCategory) -> SZUNETNetworkCategory {
        switch value {
        case .dorm: .dorm
        case .teaching: .teaching
        case .ambiguous: .ambiguous
        case .nonCampus: .nonCampus
        case .unknown: .unknown
        }
    }

    private static func providers(from snapshot: CampusProductSnapshot) -> [SZUNETProviderStatus] {
        [
            SZUNETProviderStatus(
                provider: "dorm",
                enabled: snapshot.dorm.enabled,
                accountLabel: snapshot.dorm.accountLabel,
                lifecycle: snapshot.dorm.lifecycle,
                errorCode: snapshot.dorm.errorCode
            ),
            SZUNETProviderStatus(
                provider: "teaching",
                enabled: snapshot.teaching.enabled,
                accountLabel: snapshot.teaching.accountLabel,
                lifecycle: snapshot.teaching.lifecycle,
                errorCode: snapshot.teaching.errorCode
            ),
        ]
    }

    private static func environment(from value: NetworkEnvironment) -> SZUNETEnvironment {
        if value.autoLoginAvailable { return .eligible }
        return value.isDormNetwork ? .unknown : .ineligible
    }

    private static func portal(from value: CampusSessionState) -> SZUNETPortalState {
        switch value {
        case .online: .authenticated
        case .offline: .unauthenticated
        case .unknown: .unknown
        }
    }
}

public actor SZUNETModule {
    public typealias DriverFactory = @Sendable () -> any SZUNETCoordinatorDriving

    private let driverFactory: DriverFactory
    private var driver: (any SZUNETCoordinatorDriving)?
    private var snapshot = SZUNETSnapshot()
    private var backoff = AutoLoginBackoff()
    private var generation: UInt64 = 0
    private var probeTask: Task<SZUNETProbeResult, Error>?
    private var manualTask: Task<SZUNETActionResult, Never>?
    private var automaticTask: Task<SZUNETActionResult, Never>?

    public init(driverFactory: @escaping DriverFactory = { SZUNETCoordinatorDriver() }) {
        self.driverFactory = driverFactory
    }

    public func currentSnapshot() -> SZUNETSnapshot {
        snapshot
    }

    public func configure(
        featureEnabled: Bool,
        autoLoginEnabled: Bool,
        resumeAutoLogin: Bool = false
    ) async -> SZUNETSnapshot {
        generation &+= 1
        cancelOperations()
        snapshot.status.featureEnabled = featureEnabled
        snapshot.status.autoLoginEnabled = autoLoginEnabled
        snapshot.status.errorCode = nil
        snapshot.nextAutomaticAttemptAt = nil

        guard featureEnabled else {
            // Releasing the driver also releases its configuration path. A
            // completed SZUNET takeover can therefore switch from the legacy
            // config to the unified private copy without restarting the App.
            driver = nil
            snapshot.status.environment = .unknown
            snapshot.status.portal = .unknown
            snapshot.status.internet = .unknown
            snapshot.configuration = nil
            snapshot.environmentLabel = "模块已关闭"
            snapshot.detail = "不会探测 Portal、读取校园网密码、运行退避任务或发送登录请求。"
            snapshot.manualLogoutSuppressed = false
            return snapshot
        }

        let driver = resolveDriver()
        do {
            if !autoLoginEnabled {
                try await driver.setAutoLoginEnabled(false)
                snapshot.manualLogoutSuppressed = false
            } else if resumeAutoLogin {
                try await driver.setAutoLoginEnabled(true)
                snapshot.manualLogoutSuppressed = false
                backoff.allowImmediateAttempt()
            }
            snapshot.configuration = try await driver.configurationSummary()
            snapshot.environmentLabel = "等待检查"
            snapshot.detail = autoLoginEnabled
                ? "模块已启用；自动登录仍需通过宿舍网关与校园网源 IP 双重门控。"
                : "模块已启用；自动登录已关闭，手动登录和退出仍可使用。"
        } catch {
            record(error: error, code: "campus_configuration_error")
        }
        return snapshot
    }

    public func refresh() async -> SZUNETSnapshot {
        guard snapshot.status.featureEnabled else { return snapshot }
        let operationGeneration = generation
        probeTask?.cancel()
        let driver = resolveDriver()
        let task = Task<SZUNETProbeResult, Error> {
            try Task.checkCancellation()
            return try await driver.probe()
        }
        probeTask = task
        let previousPortal = snapshot.status.portal
        snapshot.status.environment = .unknown
        snapshot.status.portal = .checking
        snapshot.status.internet = .checking
        snapshot.detail = "正在检查校园网环境与 Portal 会话…"

        do {
            let result = try await task.value
            guard operationGeneration == generation, !Task.isCancelled else { return snapshot }
            probeTask = nil
            snapshot.status.environment = result.environment
            snapshot.status.portal = result.portal
            snapshot.status.internet = result.internet
            snapshot.environmentLabel = result.environmentLabel
            snapshot.detail = Self.probeDetail(result)
            snapshot.status.errorCode = nil
            snapshot.status.networkCategory = result.networkCategory
            snapshot.status.providers = result.providers
            snapshot.manualLogoutSuppressed = snapshot.status.autoLoginEnabled && result.autoLoginPaused
            if result.portal == .unauthenticated,
               previousPortal != .unauthenticated,
               snapshot.status.autoLoginEnabled,
               !snapshot.manualLogoutSuppressed {
                backoff.allowImmediateAttempt()
            }
            snapshot.nextAutomaticAttemptAt = snapshot.status.autoLoginEnabled
                ? backoff.nextAttempt
                : nil
        } catch is CancellationError {
            if operationGeneration == generation {
                probeTask = nil
                snapshot.detail = "校园网检查已取消。"
            }
        } catch {
            if operationGeneration == generation {
                probeTask = nil
                record(error: error, code: "campus_probe_failed")
            }
        }
        return snapshot
    }

    public func runAutomaticLoginIfDue(at now: Date = Date()) async -> SZUNETSnapshot {
        guard snapshot.status.featureEnabled,
              snapshot.status.autoLoginEnabled,
              !snapshot.manualLogoutSuppressed,
              snapshot.status.environment == .eligible,
              snapshot.status.portal == .unauthenticated,
              manualTask == nil,
              automaticTask == nil else { return snapshot }
        guard backoff.consumeIfDue(at: now) else {
            snapshot.nextAutomaticAttemptAt = backoff.nextAttempt
            return snapshot
        }

        let operationGeneration = generation
        let driver = resolveDriver()
        let task = Task { await driver.automaticLogin() }
        automaticTask = task
        snapshot.detail = "已通过环境门控，正在执行受控自动登录…"
        let result = await task.value
        guard operationGeneration == generation, !Task.isCancelled else { return snapshot }
        automaticTask = nil
        apply(result, at: now, automatic: true)
        return snapshot
    }

    public func manualLogin() async -> SZUNETSnapshot {
        guard snapshot.status.featureEnabled else { return snapshot }
        generation &+= 1
        probeTask?.cancel()
        manualTask?.cancel()
        automaticTask?.cancel()
        let operationGeneration = generation
        let driver = resolveDriver()
        let task = Task { await driver.manualLogin() }
        manualTask = task
        snapshot.detail = "正在执行你明确发起的校园网登录…"
        let result = await task.value
        guard operationGeneration == generation, !Task.isCancelled else { return snapshot }
        manualTask = nil
        apply(result, at: Date(), automatic: false)
        return snapshot
    }

    public func manualLogout() async -> SZUNETSnapshot {
        guard snapshot.status.featureEnabled else { return snapshot }
        generation &+= 1
        probeTask?.cancel()
        manualTask?.cancel()
        automaticTask?.cancel()
        let operationGeneration = generation
        let driver = resolveDriver()
        let task = Task { await driver.manualLogout() }
        manualTask = task
        snapshot.detail = "正在执行你明确发起的校园网退出…"
        let result = await task.value
        guard operationGeneration == generation, !Task.isCancelled else { return snapshot }
        manualTask = nil
        if result.reason != "pause_failed" {
            snapshot.manualLogoutSuppressed = true
        }
        apply(result, at: Date(), automatic: false)
        return snapshot
    }

    public func saveCredentials(username: String, password: String?) async -> SZUNETSnapshot {
        guard snapshot.status.featureEnabled else { return snapshot }
        let driver = resolveDriver()
        do {
            try await driver.saveCredentials(username: username, password: password)
            snapshot.configuration = try await driver.configurationSummary()
            snapshot.lastAction = SZUNETActionResult(
                outcome: .unchanged,
                title: "账号设置已保存",
                detail: password?.isEmpty == false
                    ? "密码已写入当前受管 Keychain 项，不会保存到配置或日志。"
                    : "账号已更新；当前 Keychain 密码保持不变。",
                reason: "credentials_saved"
            )
            snapshot.detail = snapshot.lastAction?.detail ?? "账号设置已保存。"
            snapshot.status.errorCode = nil
        } catch {
            record(error: error, code: "campus_credentials_save_failed")
        }
        return snapshot
    }

    public func stop() {
        generation &+= 1
        cancelOperations()
        snapshot.nextAutomaticAttemptAt = nil
    }

    private func resolveDriver() -> any SZUNETCoordinatorDriving {
        if let driver { return driver }
        let newDriver = driverFactory()
        driver = newDriver
        return newDriver
    }

    private func cancelOperations() {
        probeTask?.cancel()
        manualTask?.cancel()
        automaticTask?.cancel()
        probeTask = nil
        manualTask = nil
        automaticTask = nil
    }

    private func apply(_ result: SZUNETActionResult, at date: Date, automatic: Bool) {
        snapshot.lastAction = result
        snapshot.detail = [result.title, result.detail].filter { !$0.isEmpty }.joined(separator: "：")
        switch result.outcome {
        case .authenticated:
            snapshot.status.portal = .authenticated
            snapshot.status.internet = .checking
            snapshot.status.lastSuccessAt = date
            snapshot.status.errorCode = nil
            backoff.recordSuccess(at: date)
        case .loggedOut:
            snapshot.status.portal = .unauthenticated
            snapshot.status.lastSuccessAt = date
            snapshot.status.errorCode = nil
        case .unchanged:
            if result.reason == "session_already_online" {
                snapshot.status.portal = .authenticated
                snapshot.status.lastSuccessAt = date
                backoff.recordSuccess(at: date)
            } else if result.reason == "paused" {
                snapshot.manualLogoutSuppressed = true
            }
            snapshot.status.errorCode = nil
        case .failed, .uncertain:
            snapshot.status.lastFailureAt = date
            snapshot.status.errorCode = result.reason.isEmpty ? "campus_action_failed" : result.reason
            if automatic { backoff.recordFailure(at: date) }
        case .cancelled:
            break
        }
        snapshot.nextAutomaticAttemptAt = snapshot.status.autoLoginEnabled && !snapshot.manualLogoutSuppressed
            ? backoff.nextAttempt
            : nil
    }

    private func record(error: Error, code: String) {
        snapshot.status.lastFailureAt = Date()
        snapshot.status.errorCode = code
        snapshot.detail = "校园网模块失败：\(error.localizedDescription)。Codex 与远程服务不会因此停止。"
        snapshot.lastAction = SZUNETActionResult(
            outcome: .failed,
            title: "校园网模块失败",
            detail: error.localizedDescription,
            reason: code
        )
    }

    private static func probeDetail(_ result: SZUNETProbeResult) -> String {
        let parts = [result.environmentReason, result.gatewayReason, result.internetReason]
            .filter { !$0.isEmpty && $0 != "not_probed" }
        return parts.isEmpty ? "校园网状态已更新。" : parts.joined(separator: " · ")
    }
}
