import Foundation
import Testing
@testable import SZUDormLoginApp

@Suite("App automation scheduler", .serialized)
struct AppAutomationSchedulerTests {
    @Test("cancelled probes cannot publish stale UI state")
    @MainActor
    func cancelledProbeCannotPublish() async {
        let scheduler = AppAutomationScheduler()
        let started = AsyncGate()
        let release = AsyncGate()
        var publishedValue: Int?

        #expect(scheduler.startProbe(
            operation: {
                await started.open()
                await release.wait()
                return 42
            },
            completion: { result in
                publishedValue = try? result.get()
            }
        ))

        await started.wait()
        scheduler.cancelProbe()
        await release.open()
        await settleCancelledTask()

        #expect(publishedValue == nil)
        #expect(!scheduler.isProbing)
    }

    @Test("cancelling auto-login leaves probe and manual lanes independent")
    @MainActor
    func cancellingAutoLoginLeavesOtherLanesIndependent() async {
        let scheduler = AppAutomationScheduler()
        let probeStarted = AsyncGate()
        let releaseProbe = AsyncGate()
        let autoStarted = AsyncGate()
        let releaseAuto = AsyncGate()
        var autoPublished = false
        var manualValue: Int?

        #expect(scheduler.startProbe(
            operation: {
                await probeStarted.open()
                await releaseProbe.wait()
                return 1
            },
            completion: { _ in }
        ))
        #expect(scheduler.startAutoLogin(
            operation: {
                await autoStarted.open()
                await releaseAuto.wait()
                return 2
            },
            completion: { _ in autoPublished = true }
        ))

        await probeStarted.wait()
        await autoStarted.wait()
        scheduler.cancelAutoLogin()

        #expect(scheduler.isProbing)
        #expect(!scheduler.hasActiveOperation)
        #expect(scheduler.startManualOperation(
            operation: { 7 },
            completion: { manualValue = $0 }
        ))

        await releaseAuto.open()
        await waitUntil { manualValue == 7 }
        await settleCancelledTask()

        #expect(!autoPublished)
        #expect(manualValue == 7)
        #expect(scheduler.isProbing)

        scheduler.cancelProbe()
        await releaseProbe.open()
    }
}

private actor AsyncGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<100 where !predicate() {
        await Task.yield()
    }
}

private func settleCancelledTask() async {
    try? await Task.sleep(nanoseconds: 10_000_000)
}
