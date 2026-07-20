import Combine
import Foundation

@MainActor
public final class SZUNETFeatureStore: ObservableObject {
    @Published public private(set) var snapshot = SZUNETSnapshot()
    @Published public private(set) var isWorking = false

    private let adapter: SZUNETModule
    private let refreshInterval: Duration
    private var periodicTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var started = false

    public init(
        adapter: SZUNETModule = SZUNETModule(),
        refreshInterval: Duration = .seconds(30)
    ) {
        self.adapter = adapter
        self.refreshInterval = refreshInterval
    }

    public func start(featureEnabled: Bool, autoLoginEnabled: Bool) async {
        guard !started else { return }
        started = true
        snapshot = await adapter.configure(
            featureEnabled: featureEnabled,
            autoLoginEnabled: autoLoginEnabled
        )
        guard featureEnabled else { return }
        restartPeriodicRefresh()
        await refreshAndRunAutomaticLoginIfDue()
    }

    public func settingsDidChange(
        featureEnabled: Bool,
        autoLoginEnabled: Bool,
        resumeAutoLogin: Bool
    ) {
        operationTask?.cancel()
        if !featureEnabled {
            periodicTask?.cancel()
            periodicTask = nil
        }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isWorking = true
            defer {
                self.isWorking = false
                self.operationTask = nil
            }
            self.snapshot = await self.adapter.configure(
                featureEnabled: featureEnabled,
                autoLoginEnabled: autoLoginEnabled,
                resumeAutoLogin: resumeAutoLogin
            )
            guard !Task.isCancelled, featureEnabled else { return }
            self.restartPeriodicRefresh()
            await self.refreshAndRunAutomaticLoginIfDue()
        }
    }

    public func refresh() {
        guard snapshot.status.featureEnabled else { return }
        runOperation { store in
            await store.refreshAndRunAutomaticLoginIfDue()
        }
    }

    public func manualLogin() {
        guard snapshot.status.featureEnabled else { return }
        runOperation { store in
            store.snapshot = await store.adapter.manualLogin()
            guard !Task.isCancelled else { return }
            store.snapshot = await store.adapter.refresh()
        }
    }

    public func manualLogout() {
        guard snapshot.status.featureEnabled else { return }
        runOperation { store in
            store.snapshot = await store.adapter.manualLogout()
            guard !Task.isCancelled else { return }
            store.snapshot = await store.adapter.refresh()
        }
    }

    public func saveCredentials(username: String, password: String?) {
        guard snapshot.status.featureEnabled else { return }
        runOperation { store in
            store.snapshot = await store.adapter.saveCredentials(
                username: username,
                password: password
            )
        }
    }

    @discardableResult
    public func refreshSnapshot() async -> SZUNETSnapshot {
        snapshot = await adapter.refresh()
        return snapshot
    }

    @discardableResult
    public func runAutomaticLoginIfDue() async -> SZUNETSnapshot {
        snapshot = await adapter.runAutomaticLoginIfDue()
        return snapshot
    }

    public func shutdown() async {
        periodicTask?.cancel()
        operationTask?.cancel()
        periodicTask = nil
        operationTask = nil
        await adapter.stop()
        isWorking = false
    }

    private func restartPeriodicRefresh() {
        periodicTask?.cancel()
        guard snapshot.status.featureEnabled else {
            periodicTask = nil
            return
        }
        periodicTask = Task { @MainActor [weak self, refreshInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    return
                }
                guard let self, self.snapshot.status.featureEnabled else { return }
                await self.refreshAndRunAutomaticLoginIfDue()
            }
        }
    }

    private func runOperation(
        _ operation: @escaping @MainActor (SZUNETFeatureStore) async -> Void
    ) {
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isWorking = true
            defer {
                self.isWorking = false
                self.operationTask = nil
            }
            await operation(self)
        }
    }

    private func refreshAndRunAutomaticLoginIfDue() async {
        guard snapshot.status.featureEnabled else { return }
        snapshot = await adapter.refresh()
        guard !Task.isCancelled else { return }
        snapshot = await adapter.runAutomaticLoginIfDue()
    }
}
