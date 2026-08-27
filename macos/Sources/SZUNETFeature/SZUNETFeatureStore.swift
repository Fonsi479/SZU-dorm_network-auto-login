import Combine
import Foundation

@MainActor
public final class SZUNETFeatureStore: ObservableObject {
    @Published public private(set) var snapshot = SZUNETSnapshot()
    @Published public private(set) var isWorking = false

    private let module: SZUNETModule
    private let refreshPolicy: SZUNETRefreshPolicy
    private let sleep: SZUNETRefreshSleeper
    private var fallbackTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var powerObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var presentationActivity = SZUNETPresentationActivity.inactive
    private var presentationActivities: [String: SZUNETPresentationActivity] = [:]
    private var pendingRefreshReason: SZUNETRefreshReason?
    private var operationGeneration: UInt64 = 0
    private var workingGeneration: UInt64 = 0
    private var activeWorkingGeneration: UInt64?
    private var refreshDiagnostics = SZUNETRefreshDiagnostics()
    private var started = false

    public init(
        module: SZUNETModule = SZUNETModule(),
        refreshInterval: Duration = .seconds(30),
        refreshPolicy: SZUNETRefreshPolicy? = nil,
        sleep: @escaping SZUNETRefreshSleeper = { duration, tolerance in
            let clock = ContinuousClock()
            try await clock.sleep(for: duration, tolerance: tolerance)
        }
    ) {
        self.module = module
        self.refreshPolicy = refreshPolicy ?? SZUNETRefreshPolicy(
            detailFallback: refreshInterval,
            tolerance: refreshInterval < .seconds(1) ? .zero : .seconds(15)
        )
        self.sleep = sleep
    }

    public func start(adapterEnabled: Bool) async {
        guard !started else { return }
        started = true
        installLifecycleObservers()
        snapshot = await module.configure(adapterEnabled: adapterEnabled)
        guard adapterEnabled else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        recordRequest(.launch)
        refreshDiagnostics.executed += 1
        let workingGeneration = beginWorking()
        defer { endWorking(workingGeneration) }
        let refreshed = await module.refresh()
        guard operationGeneration == generation else { return }
        snapshot = refreshed
        scheduleFallback()
    }

    public func setAdapterEnabled(_ enabled: Bool) {
        operationGeneration &+= 1
        operationTask?.cancel()
        fallbackTask?.cancel()
        followUpTask?.cancel()
        operationTask = nil
        fallbackTask = nil
        followUpTask = nil
        pendingRefreshReason = nil
        if !enabled {
            resetWorking()
        }
        let generation = operationGeneration
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let workingGeneration = self.beginWorking()
            defer { self.endWorking(workingGeneration) }
            let configured = await self.module.configure(adapterEnabled: enabled)
            guard self.operationGeneration == generation else { return }
            self.snapshot = configured
            if enabled, !Task.isCancelled {
                self.recordRequest(.dependencyChanged)
                self.refreshDiagnostics.executed += 1
                let refreshed = await self.module.refresh()
                guard self.operationGeneration == generation else { return }
                self.snapshot = refreshed
            }
            self.operationTask = nil
            self.scheduleFallback()
        }
    }

    public func refresh() {
        runOperation(reason: .user) { module in await module.refresh() }
    }

    public func check() {
        runOperation(reason: .user) { module in await module.check() }
    }

    public func manualLogin(provider: SZUNETCommandProvider = .auto) {
        runOperation(reason: .user, schedulesFollowUp: true) { module in
            await module.manualLogin(provider: provider)
        }
    }

    public func manualLogout() {
        runOperation(reason: .user, schedulesFollowUp: true) { module in
            await module.manualLogout()
        }
    }

    public func pause() {
        runOperation(reason: .user, schedulesFollowUp: true) { module in await module.pause() }
    }

    public func resume() {
        runOperation(reason: .user, schedulesFollowUp: true) { module in await module.resume() }
    }

    public func setNetworkProbeEnabled(_ enabled: Bool) {
        runOperation(reason: .user, schedulesFollowUp: true) { module in
            await module.setNetworkProbeEnabled(enabled)
        }
    }

    public func setProbeInterval(_ interval: SZUNETProbeInterval) {
        runOperation(reason: .user, schedulesFollowUp: true) { module in
            await module.setProbeInterval(interval)
        }
    }

    public func openSettings() {
        runOperation(reason: .user, schedulesFollowUp: true) { module in await module.openSettings() }
    }

    public func diagnostics() {
        runOperation(reason: .user) { module in await module.diagnostics() }
    }

    public func setPresentationActivity(
        _ activity: SZUNETPresentationActivity,
        consumerID: String = "legacy"
    ) {
        let currentConsumerActivity = presentationActivities[consumerID] ?? .inactive
        guard currentConsumerActivity != activity else { return }

        let previous = presentationActivity
        if activity == .inactive {
            presentationActivities.removeValue(forKey: consumerID)
        } else {
            presentationActivities[consumerID] = activity
        }
        presentationActivity = presentationActivities.values.max() ?? .inactive
        refreshDiagnostics.presentationActivity = presentationActivity

        guard presentationActivity != previous else { return }
        if presentationActivity == .inactive {
            followUpTask?.cancel()
            followUpTask = nil
        }
        scheduleFallback()
        if presentationActivity > previous, snapshot.adapterEnabled {
            requestStatus(reason: .becameVisible)
        }
    }

    public func networkDidChange() {
        requestStatus(reason: .networkChanged)
    }

    public func wakeDidOccur() {
        requestStatus(reason: .wake)
    }

    public func powerStateDidChange() {
        scheduleFallback()
        if presentationActivity != .inactive, snapshot.adapterEnabled {
            requestStatus(reason: .lowPowerChanged)
        }
    }

    public func diagnosticSnapshot() async -> SZUNETRefreshDiagnostics {
        var result = refreshDiagnostics
        result.presentationActivity = presentationActivity
        result.module = await module.diagnosticSnapshot()
        return result
    }

    public func shutdown() async {
        fallbackTask?.cancel()
        followUpTask?.cancel()
        operationTask?.cancel()
        fallbackTask = nil
        followUpTask = nil
        operationTask = nil
        removeLifecycleObservers()
        pendingRefreshReason = nil
        operationGeneration &+= 1
        await module.stop()
        snapshot = await module.currentSnapshot()
        resetWorking()
        presentationActivities.removeAll()
        presentationActivity = .inactive
        refreshDiagnostics.presentationActivity = .inactive
        started = false
    }

    private func requestStatus(reason: SZUNETRefreshReason) {
        guard snapshot.adapterEnabled else { return }
        recordRequest(reason)
        if operationTask != nil {
            refreshDiagnostics.coalesced += 1
            if let existing = pendingRefreshReason {
                pendingRefreshReason = priority(of: reason) >= priority(of: existing) ? reason : existing
            } else {
                pendingRefreshReason = reason
            }
            return
        }
        launchOperation(reason: reason, schedulesFollowUp: false) { module in
            await module.refresh()
        }
    }

    private func scheduleFallback() {
        fallbackTask?.cancel()
        fallbackTask = nil
        guard started, snapshot.adapterEnabled else { return }
        let delay = fallbackInterval
        let tolerance = min(refreshPolicy.tolerance, delay)
        fallbackTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(delay, tolerance)
            } catch {
                return
            }
            guard let self else { return }
            self.fallbackTask = nil
            self.requestStatus(reason: .timerFallback)
        }
    }

    private func runOperation(
        reason: SZUNETRefreshReason,
        schedulesFollowUp: Bool = false,
        _ operation: @escaping @Sendable (SZUNETModule) async -> SZUNETSnapshot
    ) {
        guard snapshot.adapterEnabled else { return }
        recordRequest(reason)
        operationTask?.cancel()
        operationGeneration &+= 1
        launchOperation(reason: reason, schedulesFollowUp: schedulesFollowUp, operation)
    }

    private func launchOperation(
        reason: SZUNETRefreshReason,
        schedulesFollowUp: Bool,
        _ operation: @escaping @Sendable (SZUNETModule) async -> SZUNETSnapshot
    ) {
        fallbackTask?.cancel()
        fallbackTask = nil
        let generation = operationGeneration
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let workingGeneration = self.beginWorking()
            defer { self.endWorking(workingGeneration) }
            self.refreshDiagnostics.executed += 1
            let updated = await operation(self.module)
            guard self.operationGeneration == generation else { return }
            self.snapshot = updated
            self.operationTask = nil

            if let pending = self.pendingRefreshReason {
                self.pendingRefreshReason = nil
                self.requestStatus(reason: pending)
            } else if schedulesFollowUp {
                self.scheduleBoundedFollowUp()
            }
            self.scheduleFallback()
        }
    }

    private func scheduleBoundedFollowUp() {
        followUpTask?.cancel()
        followUpTask = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(.seconds(2), .milliseconds(500))
            } catch {
                return
            }
            guard let self, self.snapshot.adapterEnabled else { return }
            self.followUpTask = nil
            self.requestStatus(reason: .dependencyChanged)
        }
    }

    private var fallbackInterval: Duration {
        if isPowerConstrained { return refreshPolicy.constrainedFallback }
        return switch presentationActivity {
        case .detailVisible: refreshPolicy.detailFallback
        case .summaryVisible: refreshPolicy.summaryFallback
        case .inactive: refreshPolicy.inactiveFallback
        }
    }

    private var isPowerConstrained: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        return switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        case .nominal, .fair: false
        @unknown default: true
        }
    }

    private func recordRequest(_ reason: SZUNETRefreshReason) {
        refreshDiagnostics.requested += 1
        refreshDiagnostics.requestsByReason[reason, default: 0] += 1
    }

    private func beginWorking() -> UInt64 {
        workingGeneration &+= 1
        activeWorkingGeneration = workingGeneration
        isWorking = true
        return workingGeneration
    }

    private func endWorking(_ generation: UInt64) {
        guard activeWorkingGeneration == generation else { return }
        activeWorkingGeneration = nil
        isWorking = false
    }

    private func resetWorking() {
        workingGeneration &+= 1
        activeWorkingGeneration = nil
        isWorking = false
    }

    private func priority(of reason: SZUNETRefreshReason) -> Int {
        switch reason {
        case .user: 7
        case .becameVisible: 6
        case .networkChanged, .wake: 5
        case .dependencyChanged: 4
        case .launch: 3
        case .lowPowerChanged: 2
        case .timerFallback: 1
        }
    }

    private func installLifecycleObservers() {
        guard powerObserver == nil, thermalObserver == nil else { return }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.powerStateDidChange() }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.powerStateDidChange() }
        }
    }

    private func removeLifecycleObservers() {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        powerObserver = nil
        thermalObserver = nil
    }
}
