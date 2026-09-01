import Darwin
import Dispatch
import Foundation

public protocol SZUNETCommandExecuting: Sendable {
    func execute(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider,
        interactive: Bool,
        timeoutSeconds: Int
    ) async throws -> SZUNETCommandResult
}

struct SZUNETWireResult: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let requestId: String
    let outcome: SZUNETOutcome
    let provider: SZUNETResultProvider
    let networkContext: SZUNETNetworkContext
    let sessionState: SZUNETSessionState
    let errorCode: String?
    let retryable: Bool
    let automaticEnabled: Bool?
    let ownerAppRunning: Bool?
    let networkProbeEnabled: Bool?
    let probeIntervalSeconds: Int?
    let onlineDeviceCount: Int?
    let onlineDeviceLimit: Int?
    let message: String
    let timestamp: String

    init(
        schemaVersion: Int,
        requestId: String,
        outcome: SZUNETOutcome,
        provider: SZUNETResultProvider,
        networkContext: SZUNETNetworkContext,
        sessionState: SZUNETSessionState,
        errorCode: String?,
        retryable: Bool,
        automaticEnabled: Bool?,
        ownerAppRunning: Bool?,
        networkProbeEnabled: Bool? = nil,
        probeIntervalSeconds: Int? = nil,
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil,
        message: String,
        timestamp: String
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.outcome = outcome
        self.provider = provider
        self.networkContext = networkContext
        self.sessionState = sessionState
        self.errorCode = errorCode
        self.retryable = retryable
        self.automaticEnabled = automaticEnabled
        self.ownerAppRunning = ownerAppRunning
        self.networkProbeEnabled = networkProbeEnabled
        self.probeIntervalSeconds = probeIntervalSeconds
        self.onlineDeviceCount = onlineDeviceCount
        self.onlineDeviceLimit = onlineDeviceLimit
        self.message = message
        self.timestamp = timestamp
    }
}

public enum SZUNETCLIExecutableLocator {
    public static func installed(fileManager: FileManager = .default) -> URL? {
        candidates(fileManager: fileManager).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    public static func candidates(fileManager: FileManager = .default) -> [URL] {
        let suffix = "SZU Dorm Login.app/Contents/MacOS/szu-campus-netctl"
        return [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(suffix),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(suffix),
        ]
    }
}

public actor SZUNETCLIClient: SZUNETCommandExecuting {
    typealias Transport = @Sendable (Data, Int) async throws -> Data

    static let maximumAllowedOutputBytes = 1_048_576

    private let transport: Transport
    private let requestIDFactory: @Sendable () -> String

    public init(
        executableURL: URL,
        maximumOutputBytes: Int = 1_048_576,
        requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        let runner = SZUNETProcessRunner(
            executableURL: executableURL,
            maximumOutputBytes: Self.clampedOutputLimit(maximumOutputBytes)
        )
        transport = { input, timeoutSeconds in
            try await runner.run(input: input, timeoutSeconds: timeoutSeconds)
        }
        self.requestIDFactory = requestIDFactory
    }

    init(
        transport: @escaping Transport,
        requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.requestIDFactory = requestIDFactory
    }

    public static func installed() -> SZUNETCLIClient {
        let executableURL = SZUNETCLIExecutableLocator.installed()
            ?? SZUNETCLIExecutableLocator.candidates().first!
        return SZUNETCLIClient(executableURL: executableURL)
    }

    public func execute(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider = .auto,
        interactive: Bool = false,
        timeoutSeconds: Int = 15
    ) async throws -> SZUNETCommandResult {
        do {
            try Task.checkCancellation()
        } catch {
            throw SZUNETAdapterError.cancelled
        }
        let requestID = requestIDFactory()
        guard (1...128).contains(requestID.count) else {
            throw SZUNETAdapterError.invalidResponse
        }
        let request = SZUNETCommandRequest(
            requestId: requestID,
            command: command,
            provider: provider,
            interactive: interactive,
            timeoutSeconds: timeoutSeconds
        )
        let input = try Self.encode(request)
        let output: Data
        do {
            output = try await transport(input, request.timeoutSeconds)
        } catch is CancellationError {
            throw SZUNETAdapterError.cancelled
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw SZUNETAdapterError.cancelled
        }
        return try Self.decode(output, expectedRequestID: requestID)
    }

    static func encode(_ request: SZUNETCommandRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(request)
        data.append(0x0A)
        return data
    }

    static func clampedOutputLimit(_ value: Int) -> Int {
        min(max(4_096, value), maximumAllowedOutputBytes)
    }

    static func decode(
        _ data: Data,
        expectedRequestID: String
    ) throws -> SZUNETCommandResult {
        guard !data.isEmpty else { throw SZUNETAdapterError.invalidResponse }
        let decoder = JSONDecoder()
        guard let wire = try? decoder.decode(SZUNETWireResult.self, from: data),
              wire.message.utf8.count <= 1_000,
              wire.timestamp.utf8.count <= 64 else {
            throw SZUNETAdapterError.invalidResponse
        }
        guard wire.schemaVersion == 1 else {
            throw SZUNETAdapterError.unsupportedSchema
        }
        guard wire.requestId == expectedRequestID else {
            throw SZUNETAdapterError.requestMismatch
        }
        return SZUNETCommandResult(
            schemaVersion: wire.schemaVersion,
            requestId: wire.requestId,
            outcome: wire.outcome,
            provider: wire.provider,
            networkContext: wire.networkContext,
            sessionState: wire.sessionState,
            errorCode: wire.errorCode,
            retryable: wire.retryable,
            automaticEnabled: wire.automaticEnabled,
            ownerAppRunning: wire.ownerAppRunning,
            networkProbeEnabled: wire.networkProbeEnabled,
            probeIntervalSeconds: wire.probeIntervalSeconds,
            onlineDeviceCount: wire.onlineDeviceCount,
            onlineDeviceLimit: wire.onlineDeviceLimit,
            observedAt: ISO8601DateFormatter().date(from: wire.timestamp)
        )
    }
}

public actor SZUNETModule {
    private let executor: any SZUNETCommandExecuting
    private var snapshot = SZUNETSnapshot()
    private var generation: UInt64 = 0
    private var activeTask: Task<SZUNETCommandResult, Error>?
    private var diagnostics = SZUNETModuleDiagnostics()

    public init(executor: any SZUNETCommandExecuting = SZUNETCLIClient.installed()) {
        self.executor = executor
    }

    public func currentSnapshot() -> SZUNETSnapshot {
        snapshot
    }

    public func configure(adapterEnabled: Bool) -> SZUNETSnapshot {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        snapshot.adapterEnabled = adapterEnabled
        if adapterEnabled {
            snapshot.detail = "校园网功能已启用；认证与设置由当前执行器管理。"
        } else {
            snapshot.status = nil
            snapshot.lastAction = nil
            snapshot.detail = "校园网功能已关闭；不会读取状态或发送认证请求。"
        }
        return snapshot
    }

    public func refresh() async -> SZUNETSnapshot {
        await perform(.status)
    }

    public func check() async -> SZUNETSnapshot {
        await perform(.check)
    }

    public func manualLogin(provider: SZUNETCommandProvider = .auto) async -> SZUNETSnapshot {
        await perform(.login, provider: provider, interactive: true)
    }

    /// Explicitly acknowledged device-limit takeover.  The UI owns the
    /// confirmation step; this method only dispatches the high-level command
    /// after that confirmation has happened.
    public func forceLogin(provider: SZUNETCommandProvider = .auto) async -> SZUNETSnapshot {
        await perform(.forceLogin, provider: provider, interactive: true)
    }

    public func manualLogout() async -> SZUNETSnapshot {
        await perform(.logout, provider: .dorm, interactive: true)
    }

    public func pause() async -> SZUNETSnapshot {
        await perform(.pause)
    }

    public func resume() async -> SZUNETSnapshot {
        await perform(.resume)
    }

    public func setNetworkProbeEnabled(_ enabled: Bool) async -> SZUNETSnapshot {
        await perform(enabled ? .enableProbe : .disableProbe)
    }

    public func setProbeInterval(_ interval: SZUNETProbeInterval) async -> SZUNETSnapshot {
        await perform(interval.command)
    }

    public func openSettings() async -> SZUNETSnapshot {
        await perform(.openSettings, interactive: true)
    }

    public func diagnostics() async -> SZUNETSnapshot {
        await perform(.diagnostics)
    }

    public func stop() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        snapshot = SZUNETSnapshot()
    }

    public func diagnosticSnapshot() -> SZUNETModuleDiagnostics {
        diagnostics
    }

    private func perform(
        _ command: SZUNETCommand,
        provider: SZUNETCommandProvider = .auto,
        interactive: Bool = false
    ) async -> SZUNETSnapshot {
        guard snapshot.adapterEnabled else { return snapshot }
        generation &+= 1
        activeTask?.cancel()
        let operationGeneration = generation
        diagnostics.commandExecutions[command, default: 0] += 1
        let task = Task {
            try await executor.execute(
                command,
                provider: provider,
                interactive: interactive,
                timeoutSeconds: command == .status ? 10 : 30
            )
        }
        activeTask = task
        do {
            let result = try await task.value
            guard generation == operationGeneration, snapshot.adapterEnabled else {
                return snapshot
            }
            activeTask = nil
            if Self.isStatusCommand(command) {
                snapshot.status = result
            } else {
                snapshot.lastAction = result
                if Self.updatesControlState(command) {
                    snapshot.status = result
                }
            }
            snapshot.detail = Self.detail(for: result)
        } catch {
            guard generation == operationGeneration, snapshot.adapterEnabled else {
                diagnostics.cancelledExecutions += 1
                return snapshot
            }
            activeTask = nil
            let code = Self.code(for: error)
            let result = SZUNETCommandResult.blocked(
                requestId: "adapter-error",
                code: code
            )
            if Self.isStatusCommand(command) {
                snapshot.status = result
            } else {
                snapshot.lastAction = result
            }
            snapshot.detail = result.errorCode ?? result.outcome.rawValue
        }
        return snapshot
    }

    private static func detail(for result: SZUNETCommandResult) -> String {
        if let code = result.errorCode, !code.isEmpty { return code }
        return result.outcome.rawValue
    }

    private static func isStatusCommand(_ command: SZUNETCommand) -> Bool {
        command == .status || command == .check || command == .diagnostics
    }

    private static func updatesControlState(_ command: SZUNETCommand) -> Bool {
        switch command {
        case .pause, .resume, .enableProbe, .disableProbe,
             .probeEvery30Seconds, .probeEvery60Seconds,
             .probeEvery120Seconds, .probeEvery300Seconds:
            true
        case .status, .check, .login, .forceLogin, .logout, .openSettings, .diagnostics:
            false
        }
    }

    private static func code(for error: Error) -> String {
        guard let adapterError = error as? SZUNETAdapterError else {
            return "ADAPTER_INTERNAL"
        }
        return switch adapterError {
        case .executableUnavailable: "ADAPTER_CLI_UNAVAILABLE"
        case .launchFailed: "ADAPTER_CLI_LAUNCH_FAILED"
        case .outputTooLarge: "ADAPTER_OUTPUT_TOO_LARGE"
        case .timedOut: "ADAPTER_TIMEOUT"
        case .cancelled: "OPERATION_CANCELLED"
        case .invalidResponse: "ADAPTER_INVALID_RESPONSE"
        case .unsupportedSchema: "ADAPTER_SCHEMA_MISMATCH"
        case .requestMismatch: "ADAPTER_REQUEST_MISMATCH"
        }
    }
}

final class SZUNETProcessRunner: @unchecked Sendable {
    private let executableURL: URL
    private let maximumOutputBytes: Int

    init(executableURL: URL, maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(input: Data, timeoutSeconds: Int) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SZUNETAdapterError.executableUnavailable
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--json"]
        process.environment = Self.minimumEnvironment()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let state = SZUNETChildProcessState(
            process,
            handles: [
                standardInput.fileHandleForReading,
                standardInput.fileHandleForWriting,
                standardOutput.fileHandleForReading,
                standardOutput.fileHandleForWriting,
                standardError.fileHandleForReading,
                standardError.fileHandleForWriting,
            ]
        )
        defer { state.closeHandles() }
        do {
            try process.run()
            state.isolateProcessGroupIfPossible()
            // The child owns these pipe ends after launch. Keeping the parent
            // copies open can prevent EOF from reaching the bounded readers.
            try? standardInput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try standardInput.fileHandleForWriting.write(contentsOf: input)
            try standardInput.fileHandleForWriting.close()
        } catch {
            state.forceStop()
            throw SZUNETAdapterError.launchFailed
        }

        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { [maximumOutputBytes] in
                        async let output = Self.drain(
                            standardOutput.fileHandleForReading,
                            maximumBytes: maximumOutputBytes
                        )
                        async let errors = Self.drain(
                            standardError.fileHandleForReading,
                            maximumBytes: 65_536
                        )
                        await Self.waitUntilExit(process)
                        let (outputResult, errorResult) = await (output, errors)
                        guard !outputResult.exceeded, !errorResult.exceeded else {
                            throw SZUNETAdapterError.outputTooLarge
                        }
                        return outputResult.data
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        throw SZUNETAdapterError.timedOut
                    }
                    defer { group.cancelAll() }
                    do {
                        guard let first = try await group.next() else {
                            throw SZUNETAdapterError.invalidResponse
                        }
                        return first
                    } catch {
                        state.forceStop()
                        throw error
                    }
                }
            } catch is CancellationError {
                state.forceStop()
                throw SZUNETAdapterError.cancelled
            }
        } onCancel: {
            state.forceStop()
        }
    }

    static func minimumEnvironment(
        fileManager: FileManager = .default
    ) -> [String: String] {
        [
            "HOME": fileManager.homeDirectoryForCurrentUser.path,
            "TMPDIR": fileManager.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
        ]
    }

    private static func drain(
        _ handle: FileHandle,
        maximumBytes: Int
    ) async -> (data: Data, exceeded: Bool) {
        let blockingHandle = SZUNETBlockingFileHandle(handle)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var collected = Data()
                var exceeded = false
                while true {
                    let chunk: Data
                    do {
                        guard let next = try blockingHandle.handle.read(upToCount: 65_536),
                              !next.isEmpty else {
                            break
                        }
                        chunk = next
                    } catch {
                        break
                    }
                    let remaining = max(0, maximumBytes - collected.count)
                    if chunk.count > remaining { exceeded = true }
                    if remaining > 0 { collected.append(chunk.prefix(remaining)) }
                }
                continuation.resume(returning: (collected, exceeded))
            }
        }
    }

    private static func waitUntilExit(_ process: Process) async {
        let observer = SZUNETProcessTerminationObserver(process)
        await observer.wait()
    }
}

private final class SZUNETBlockingFileHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

private final class SZUNETProcessTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    init(_ process: Process) {
        self.process = process
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()

            process.terminationHandler = { [self] _ in finish() }
            if !process.isRunning { finish() }
        }
    }

    private func finish() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        process.terminationHandler = nil
        continuation?.resume()
    }
}

private final class SZUNETChildProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let handles: [FileHandle]
    private var isolatedProcessGroup = false
    private var handlesClosed = false

    init(_ process: Process, handles: [FileHandle]) {
        self.process = process
        self.handles = handles
    }

    func isolateProcessGroupIfPossible() {
        lock.lock()
        defer { lock.unlock() }
        let processID = process.processIdentifier
        guard processID > 0 else { return }
        if Darwin.setpgid(processID, processID) == 0 || Darwin.getpgid(processID) == processID {
            isolatedProcessGroup = true
        }
    }

    func forceStop() {
        lock.lock()
        let processID = process.processIdentifier
        let shouldStop = processID > 0 && process.isRunning
        let stopGroup = isolatedProcessGroup
        let handles = takeHandlesLocked()
        lock.unlock()

        if processID > 0, stopGroup {
            // A descendant can keep stdout/stderr open after the direct child
            // exits, so terminate the isolated group even when Process already
            // reports the direct child as stopped.
            _ = Darwin.kill(-processID, SIGKILL)
        } else if shouldStop {
            _ = Darwin.kill(processID, SIGKILL)
        }
        for handle in handles { try? handle.close() }
    }

    func closeHandles() {
        lock.lock()
        let handles = takeHandlesLocked()
        lock.unlock()
        for handle in handles { try? handle.close() }
    }

    private func takeHandlesLocked() -> [FileHandle] {
        guard !handlesClosed else { return [] }
        handlesClosed = true
        return handles
    }
}
