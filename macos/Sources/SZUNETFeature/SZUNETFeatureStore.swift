import Combine
import Foundation

@MainActor
public final class SZUNETFeatureStore: ObservableObject {
    @Published public private(set) var snapshot = SZUNETSnapshot()
    @Published public private(set) var isWorking = false

    private let module: SZUNETModule
    private let refreshInterval: Duration
    private var periodicTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var started = false

    public init(
        module: SZUNETModule = SZUNETModule(),
        refreshInterval: Duration = .seconds(30)
    ) {
        self.module = module
        self.refreshInterval = refreshInterval
    }

    public func start(adapterEnabled: Bool) async {
        guard !started else { return }
        started = true
        snapshot = await module.configure(adapterEnabled: adapterEnabled)
        guard adapterEnabled else { return }
        restartPeriodicStatus()
        snapshot = await module.refresh()
    }

    public func setAdapterEnabled(_ enabled: Bool) {
        operationTask?.cancel()
        if !enabled {
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
            self.snapshot = await self.module.configure(adapterEnabled: enabled)
            guard enabled, !Task.isCancelled else { return }
            self.restartPeriodicStatus()
            self.snapshot = await self.module.refresh()
        }
    }

    public func refresh() {
        runOperation { module in await module.refresh() }
    }

    public func check() {
        runOperation { module in await module.check() }
    }

    public func manualLogin(provider: SZUNETCommandProvider = .auto) {
        runOperation { module in await module.manualLogin(provider: provider) }
    }

    public func manualLogout() {
        runOperation { module in await module.manualLogout() }
    }

    public func pause() {
        runOperation { module in await module.pause() }
    }

    public func resume() {
        runOperation { module in await module.resume() }
    }

    public func openSettings() {
        runOperation { module in await module.openSettings() }
    }

    public func diagnostics() {
        runOperation { module in await module.diagnostics() }
    }

    public func shutdown() async {
        periodicTask?.cancel()
        operationTask?.cancel()
        periodicTask = nil
        operationTask = nil
        await module.stop()
        snapshot = await module.currentSnapshot()
        isWorking = false
        started = false
    }

    private func restartPeriodicStatus() {
        periodicTask?.cancel()
        guard snapshot.adapterEnabled else {
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
                guard let self, self.snapshot.adapterEnabled else { return }
                self.snapshot = await self.module.refresh()
            }
        }
    }

    private func runOperation(
        _ operation: @escaping @Sendable (SZUNETModule) async -> SZUNETSnapshot
    ) {
        guard snapshot.adapterEnabled else { return }
        operationTask?.cancel()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isWorking = true
            defer {
                self.isWorking = false
                self.operationTask = nil
            }
            self.snapshot = await operation(self.module)
        }
    }
}
