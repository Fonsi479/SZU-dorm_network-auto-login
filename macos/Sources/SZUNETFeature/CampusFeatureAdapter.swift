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
    let message: String
    let timestamp: String
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
            retryable: wire.retryable
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
            snapshot.detail = "适配已启用；认证与设置仍由独立 SZUNET App 管理。"
        } else {
            snapshot.status = nil
            snapshot.lastAction = nil
            snapshot.detail = "适配已关闭；不会启动独立校园网 CLI。"
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

    public func manualLogout() async -> SZUNETSnapshot {
        await perform(.logout, provider: .dorm, interactive: true)
    }

    public func pause() async -> SZUNETSnapshot {
        await perform(.pause)
    }

    public func resume() async -> SZUNETSnapshot {
        await perform(.resume)
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
            if command == .status || command == .check || command == .diagnostics {
                snapshot.status = result
            } else {
                snapshot.lastAction = result
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
            if command == .status || command == .check || command == .diagnostics {
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
        let blockingProcess = SZUNETBlockingProcess(process)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                blockingProcess.process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

private final class SZUNETBlockingFileHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

private final class SZUNETBlockingProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
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
        closeHandlesLocked()
        if shouldStop {
            process.terminate()
            if stopGroup {
                _ = Darwin.kill(-processID, SIGKILL)
            } else {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
        lock.unlock()
    }

    func closeHandles() {
        lock.lock()
        closeHandlesLocked()
        lock.unlock()
    }

    private func closeHandlesLocked() {
        guard !handlesClosed else { return }
        handlesClosed = true
        for handle in handles { try? handle.close() }
    }
}
