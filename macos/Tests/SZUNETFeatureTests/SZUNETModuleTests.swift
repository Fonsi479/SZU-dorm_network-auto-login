import Foundation
import Testing
@testable import SZUNETFeature

private struct RecordedCommand: Equatable, Sendable {
    var command: SZUNETCommand
    var provider: SZUNETCommandProvider
    var interactive: Bool
    var timeoutSeconds: Int
}

private actor FakeCommandExecutor: SZUNETCommandExecuting {
    private var commands: [RecordedCommand] = []
    private let result: SZUNETCommandResult

    init(
        result: SZUNETCommandResult = SZUNETCommandResult(
            requestId: "fixture",
            outcome: .unchanged,
            provider: .dorm,
            networkContext: .dorm,
            sessionState: .online
        )
    ) {
        self.result = result
    }

    func execute(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider,
        interactive: Bool,
        timeoutSeconds: Int
    ) async throws -> SZUNETCommandResult {
        commands.append(
            RecordedCommand(
                command: command,
                provider: provider,
                interactive: interactive,
                timeoutSeconds: timeoutSeconds
            )
        )
        return result
    }

    func recordedCommands() -> [RecordedCommand] { commands }
}

private actor BlockingCommandExecutor: SZUNETCommandExecuting {
    private var commands: [RecordedCommand] = []
    private var blockedContinuation: CheckedContinuation<SZUNETCommandResult, Never>?
    private var cancellationObserved = false
    private let lateResult = SZUNETCommandResult(
        requestId: "late-result",
        outcome: .succeeded,
        provider: .teaching,
        networkContext: .teaching,
        sessionState: .online
    )

    func execute(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider,
        interactive: Bool,
        timeoutSeconds: Int
    ) async throws -> SZUNETCommandResult {
        commands.append(
            RecordedCommand(
                command: command,
                provider: provider,
                interactive: interactive,
                timeoutSeconds: timeoutSeconds
            )
        )
        return await withTaskCancellationHandler {
            await waitForRelease()
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        while blockedContinuation == nil {
            await Task.yield()
        }
    }

    func waitUntilCancellationObserved() async {
        while !cancellationObserved {
            await Task.yield()
        }
    }

    func releaseLateResult() {
        let continuation = blockedContinuation
        blockedContinuation = nil
        continuation?.resume(returning: lateResult)
    }

    func recordedCommands() -> [RecordedCommand] { commands }

    private func waitForRelease() async -> SZUNETCommandResult {
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    private func recordCancellation() {
        cancellationObserved = true
    }
}

@Suite("SZUNET CLI consumer module")
struct SZUNETModuleTests {
    @Test("disabled adapter sends no CLI command")
    func disabledAdapterIsPassive() async {
        let executor = FakeCommandExecutor()
        let module = SZUNETModule(executor: executor)

        _ = await module.configure(adapterEnabled: false)
        _ = await module.refresh()
        _ = await module.check()
        _ = await module.manualLogin(provider: .teaching)
        _ = await module.manualLogout()
        _ = await module.pause()
        _ = await module.resume()
        _ = await module.openSettings()
        _ = await module.diagnostics()

        #expect(await executor.recordedCommands().isEmpty)
    }

    @Test("status refresh sends only a bounded status command")
    func statusRefreshUsesConsumerBoundary() async {
        let executor = FakeCommandExecutor()
        let module = SZUNETModule(executor: executor)
        _ = await module.configure(adapterEnabled: true)

        let snapshot = await module.refresh()

        #expect(snapshot.status?.networkContext == .dorm)
        #expect(await executor.recordedCommands() == [
            RecordedCommand(
                command: .status,
                provider: .auto,
                interactive: false,
                timeoutSeconds: 10
            ),
        ])
    }

    @Test("all user actions stay high-level CLI commands")
    func actionsRemainHighLevel() async {
        let executor = FakeCommandExecutor()
        let module = SZUNETModule(executor: executor)
        _ = await module.configure(adapterEnabled: true)

        _ = await module.manualLogin(provider: .teaching)
        _ = await module.manualLogout()
        _ = await module.pause()
        _ = await module.resume()
        _ = await module.openSettings()
        _ = await module.diagnostics()

        let commands = await executor.recordedCommands()
        #expect(commands.map(\.command) == [
            .login, .logout, .pause, .resume, .openSettings, .diagnostics,
        ])
        #expect(commands[0].provider == .teaching)
        #expect(commands[0].interactive)
        #expect(commands[1].provider == .dorm)
        #expect(commands[1].interactive)
        #expect(commands[2...].allSatisfy { $0.timeoutSeconds == 30 })
    }

    @Test("disabling the adapter cancels in-flight status and rejects its late result")
    func disablingAdapterCancelsInFlightCommand() async {
        let executor = BlockingCommandExecutor()
        let module = SZUNETModule(executor: executor)
        _ = await module.configure(adapterEnabled: true)

        let refreshTask = Task { await module.refresh() }
        await executor.waitUntilStarted()

        let disabledSnapshot = await module.configure(adapterEnabled: false)
        await executor.waitUntilCancellationObserved()
        await executor.releaseLateResult()

        let completedSnapshot = await refreshTask.value
        let currentSnapshot = await module.currentSnapshot()
        #expect(await executor.recordedCommands() == [
            RecordedCommand(
                command: .status,
                provider: .auto,
                interactive: false,
                timeoutSeconds: 10
            ),
        ])
        #expect(!disabledSnapshot.adapterEnabled)
        #expect(disabledSnapshot.status == nil)
        #expect(disabledSnapshot.lastAction == nil)
        #expect(completedSnapshot == disabledSnapshot)
        #expect(currentSnapshot == disabledSnapshot)
    }

    @Test("stopping the module cancels an in-flight action and rejects its late result")
    func stoppingModuleCancelsInFlightCommand() async {
        let executor = BlockingCommandExecutor()
        let module = SZUNETModule(executor: executor)
        _ = await module.configure(adapterEnabled: true)

        let loginTask = Task { await module.manualLogin(provider: .teaching) }
        await executor.waitUntilStarted()

        await module.stop()
        let stoppedSnapshot = await module.currentSnapshot()
        await executor.waitUntilCancellationObserved()
        await executor.releaseLateResult()

        let completedSnapshot = await loginTask.value
        let currentSnapshot = await module.currentSnapshot()
        #expect(await executor.recordedCommands() == [
            RecordedCommand(
                command: .login,
                provider: .teaching,
                interactive: true,
                timeoutSeconds: 30
            ),
        ])
        #expect(!stoppedSnapshot.adapterEnabled)
        #expect(stoppedSnapshot.status == nil)
        #expect(stoppedSnapshot.lastAction == nil)
        #expect(completedSnapshot == stoppedSnapshot)
        #expect(currentSnapshot == stoppedSnapshot)
    }

    @Test("periodic consumer work can only refresh status")
    @MainActor
    func storeDoesNotScheduleAuthentication() async {
        let executor = FakeCommandExecutor()
        let module = SZUNETModule(executor: executor)
        let store = SZUNETFeatureStore(
            module: module,
            refreshInterval: .milliseconds(10)
        )

        await store.start(adapterEnabled: true)
        try? await Task.sleep(for: .milliseconds(45))
        await store.shutdown()

        let commands = await executor.recordedCommands()
        #expect(commands.count >= 2)
        #expect(commands.allSatisfy { $0.command == .status })
    }
}
