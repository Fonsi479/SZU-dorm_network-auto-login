import Foundation
import SZUNetCore

/// Owns every timer and long-running task used by the menu-bar automation layer.
///
/// The scheduler deliberately keeps probes, user-initiated work, and automatic
/// login work in separate lanes. Each lane has an epoch so a cancelled task may
/// finish its underlying system call without being allowed to publish stale UI
/// state or start another operation.
@MainActor
final class AppAutomationScheduler {
    private(set) var probeTask: Task<Void, Never>?
    private(set) var manualTask: Task<Void, Never>?
    private(set) var autoLoginTask: Task<Void, Never>?

    private var startupTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var probeEpoch: UInt64 = 0
    private var manualEpoch: UInt64 = 0
    private var autoLoginEpoch: UInt64 = 0
    private var startupEpoch: UInt64 = 0
    private var timerEpoch: UInt64 = 0
    private var backoff = AutoLoginBackoff()

    var isProbing: Bool { probeTask != nil }
    var hasActiveOperation: Bool { manualTask != nil || autoLoginTask != nil }
    var hasManualOperation: Bool { manualTask != nil }

    deinit {
        refreshTimer?.invalidate()
        startupTask?.cancel()
        probeTask?.cancel()
        manualTask?.cancel()
        autoLoginTask?.cancel()
    }

    func startTimers(
        periodicInterval: TimeInterval,
        initialDelay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        stopTimers()
        timerEpoch &+= 1
        let activeTimerEpoch = timerEpoch
        refreshTimer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.timerEpoch == activeTimerEpoch else { return }
                action()
            }
        }

        startupEpoch &+= 1
        let epoch = startupEpoch
        startupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, initialDelay) * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.startupEpoch == epoch else { return }
            self.startupTask = nil
            action()
        }
    }

    func stop() {
        stopTimers()
        cancelProbe()
        cancelManualOperation()
        cancelAutoLogin()
    }

    @discardableResult
    func startProbe<Value>(
        operation: @escaping @MainActor () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) -> Bool {
        guard probeTask == nil else { return false }

        probeEpoch &+= 1
        let epoch = probeEpoch
        probeTask = Task { [weak self] in
            let result: Result<Value, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            let accepted = !Task.isCancelled && self.probeEpoch == epoch
            if self.probeEpoch == epoch {
                self.probeTask = nil
            }
            guard accepted else { return }
            completion(result)
        }
        return true
    }

    func cancelProbe() {
        probeEpoch &+= 1
        probeTask?.cancel()
        probeTask = nil
    }

    @discardableResult
    func startManualOperation<Value>(
        operation: @escaping @MainActor () async -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) -> Bool {
        guard manualTask == nil, autoLoginTask == nil else { return false }

        manualEpoch &+= 1
        let epoch = manualEpoch
        manualTask = Task { [weak self] in
            let value = await operation()
            guard let self else { return }
            let accepted = !Task.isCancelled && self.manualEpoch == epoch
            if self.manualEpoch == epoch {
                self.manualTask = nil
            }
            guard accepted else { return }
            completion(value)
        }
        return true
    }

    @discardableResult
    func startAutoLogin<Value>(
        operation: @escaping @MainActor () async -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) -> Bool {
        guard manualTask == nil, autoLoginTask == nil else { return false }

        autoLoginEpoch &+= 1
        let epoch = autoLoginEpoch
        autoLoginTask = Task { [weak self] in
            let value = await operation()
            guard let self else { return }
            let accepted = !Task.isCancelled && self.autoLoginEpoch == epoch
            if self.autoLoginEpoch == epoch {
                self.autoLoginTask = nil
            }
            guard accepted else { return }
            completion(value)
        }
        return true
    }

    func cancelAutoLogin() {
        autoLoginEpoch &+= 1
        autoLoginTask?.cancel()
        autoLoginTask = nil
    }

    func consumeAutoLoginDeadline() -> Bool {
        backoff.consumeIfDue()
    }

    func recordAutoLoginSuccess() {
        backoff.recordSuccess()
    }

    func recordAutoLoginFailure() {
        backoff.recordFailure()
    }

    private func stopTimers() {
        timerEpoch &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        startupEpoch &+= 1
        startupTask?.cancel()
        startupTask = nil
    }

    private func cancelManualOperation() {
        manualEpoch &+= 1
        manualTask?.cancel()
        manualTask = nil
    }
}
