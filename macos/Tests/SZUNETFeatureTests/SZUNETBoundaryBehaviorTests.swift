import Darwin
import Foundation
import Testing
@testable import SZUNETFeature

private actor RequestRecorder {
    private var request: SZUNETCommandRequest?

    func record(_ value: SZUNETCommandRequest) { request = value }
    func current() -> SZUNETCommandRequest? { request }
}

@Suite("SZUNET CLI adapter boundary", .serialized)
struct SZUNETBoundaryBehaviorTests {
    @Test("force-login keeps the stable wire command spelling")
    func forceLoginWireSpelling() {
        #expect(SZUNETCommand.forceLogin.rawValue == "force-login")
    }

    @Test("request encoding contains only the public command contract")
    func requestHasExactFields() throws {
        let request = SZUNETCommandRequest(
            requestId: "fixture-request",
            command: .login,
            provider: .dorm,
            interactive: true,
            timeoutSeconds: 15
        )
        let data = try SZUNETCLIClient.encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(object.keys) == [
            "schemaVersion", "requestId", "command", "provider", "interactive", "timeoutSeconds",
        ])
        let serialized = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["password", "secret", "token", "cookie", "authorization", "credentialvalue"] {
            #expect(!serialized.contains(forbidden))
        }
    }

    @Test("typed client validates schema and request identity")
    func clientValidatesResponseEnvelope() async throws {
        let recorder = RequestRecorder()
        let client = SZUNETCLIClient(
            transport: { input, _ in
                let request = try JSONDecoder().decode(SZUNETCommandRequest.self, from: input)
                await recorder.record(request)
                return try encodeWireResult(requestId: request.requestId)
            },
            requestIDFactory: { "typed-request" }
        )

        let result = try await client.execute(
            .status,
            provider: .auto,
            interactive: false,
            timeoutSeconds: 9
        )

        #expect(result.requestId == "typed-request")
        #expect(result.sessionState == .online)
        #expect(result.automaticEnabled == true)
        #expect(result.ownerAppRunning == true)
        #expect(result.networkProbeEnabled == true)
        #expect(result.probeIntervalSeconds == 120)
        #expect(result.observedAt != nil)
        let request = await recorder.current()
        #expect(request?.command == .status)
        #expect(request?.timeoutSeconds == 9)
    }

    @Test("schema and request mismatch fail closed")
    func mismatchedResponsesAreRejected() throws {
        let wrongSchema = try encodeWireResult(
            schemaVersion: 2,
            requestId: "expected"
        )
        do {
            _ = try SZUNETCLIClient.decode(wrongSchema, expectedRequestID: "expected")
            Issue.record("unsupported schema unexpectedly decoded")
        } catch let error as SZUNETAdapterError {
            #expect(error == .unsupportedSchema)
        }

        let wrongRequest = try encodeWireResult(requestId: "other")
        do {
            _ = try SZUNETCLIClient.decode(wrongRequest, expectedRequestID: "expected")
            Issue.record("mismatched request unexpectedly decoded")
        } catch let error as SZUNETAdapterError {
            #expect(error == .requestMismatch)
        }
    }

    @Test("older CLI responses remain compatible when automation fields are absent")
    func olderResponseWithoutAutomationFieldsDecodes() throws {
        let data = Data(
            #"{"schemaVersion":1,"requestId":"legacy","outcome":"unchanged","provider":"auto","networkContext":"unknown","sessionState":"unknown","errorCode":null,"retryable":false,"message":"unchanged","timestamp":"2026-07-28T00:00:00Z"}"#.utf8
        )

        let result = try SZUNETCLIClient.decode(data, expectedRequestID: "legacy")

        #expect(result.automaticEnabled == nil)
        #expect(result.ownerAppRunning == nil)
        #expect(result.networkProbeEnabled == nil)
        #expect(result.probeIntervalSeconds == nil)
    }

    @Test("schema-v1 device occupancy fields decode when present")
    func deviceOccupancyFieldsDecode() throws {
        let data = try encodeWireResult(
            requestId: "device-count",
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3
        )

        let result = try SZUNETCLIClient.decode(data, expectedRequestID: "device-count")

        #expect(result.onlineDeviceCount == 3)
        #expect(result.onlineDeviceLimit == 3)
    }

    @Test("untrusted wire detail and unknown code never reach the public result")
    func untrustedWireTextIsNotExposed() throws {
        let rawMarker = "RAW_PRIVATE_FIXTURE_198_51_100_8"
        let data = try encodeWireResult(
            requestId: "sanitized-response",
            errorCode: "UNRECOGNIZED_SERVER_DETAIL",
            message: rawMarker
        )

        let result = try SZUNETCLIClient.decode(
            data,
            expectedRequestID: "sanitized-response"
        )

        #expect(result.errorCode == "ADAPTER_UNRECOGNIZED_CODE")
        #expect(!String(describing: result).contains(rawMarker))
        let publicLabels = Set(Mirror(reflecting: result).children.compactMap(\.label))
        #expect(!publicLabels.contains("message"))
        #expect(!publicLabels.contains("timestamp"))
    }

    @Test("automation ownership conflict remains a stable public safety code")
    func ownershipConflictRemainsPublic() {
        let result = SZUNETCommandResult(
            requestId: "owner-conflict",
            outcome: .blocked,
            errorCode: "AUTOMATION_OWNER_CONFLICT"
        )

        #expect(result.errorCode == "AUTOMATION_OWNER_CONFLICT")
    }

    @Test("process environment is an exact minimal allowlist")
    func processEnvironmentIsMinimal() {
        let environment = SZUNETProcessRunner.minimumEnvironment()
        #expect(Set(environment.keys) == ["HOME", "TMPDIR", "PATH", "LANG", "LC_CTYPE"])
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment.values.allSatisfy { !$0.isEmpty })
    }

    @Test("output limit is clamped at both security bounds")
    func outputLimitIsClamped() {
        #expect(SZUNETCLIClient.clampedOutputLimit(-1) == 4_096)
        #expect(
            SZUNETCLIClient.clampedOutputLimit(Int.max)
                == SZUNETCLIClient.maximumAllowedOutputBytes
        )
    }

    @Test("transport cancellation and timeout remain sanitized")
    func transportFailuresStayTyped() async {
        let cancelled = SZUNETCLIClient(
            transport: { _, _ in throw CancellationError() },
            requestIDFactory: { "cancelled" }
        )
        do {
            _ = try await cancelled.execute(.status)
            Issue.record("cancelled transport unexpectedly returned")
        } catch let error as SZUNETAdapterError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected cancellation error type")
        }

        let timedOut = SZUNETCLIClient(
            transport: { _, _ in throw SZUNETAdapterError.timedOut },
            requestIDFactory: { "timeout" }
        )
        do {
            _ = try await timedOut.execute(.status)
            Issue.record("timed-out transport unexpectedly returned")
        } catch let error as SZUNETAdapterError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected timeout error type")
        }
    }

    @Test("live process transport uses one bounded JSON exchange")
    func processTransportUsesJSONBoundary() async throws {
        let response = try wireJSONString(requestId: "process-request")
        let fixture = try makeExecutableFixture(
            "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '\(response)'\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = SZUNETCLIClient(
            executableURL: fixture.executable,
            requestIDFactory: { "process-request" }
        )

        let result = try await client.execute(
            .status,
            provider: .auto,
            interactive: false,
            // This test verifies the one-request JSON boundary, not the
            // timeout path. Use the production status budget so a loaded CI
            // runner cannot turn process scheduling latency into a false
            // boundary failure; dedicated tests below keep the 1-second
            // timeout and descendant-termination contract covered.
            timeoutSeconds: 10
        )

        #expect(result.sessionState == .online)
        #expect(result.networkContext == .dorm)
    }

    @Test("rapid child exits never strand a process waiter")
    func rapidProcessExitsRemainBounded() async throws {
        let response = try wireJSONString(requestId: "rapid-process")
        let fixture = try makeExecutableFixture(
            "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '\(response)'\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = SZUNETCLIClient(
            executableURL: fixture.executable,
            requestIDFactory: { "rapid-process" }
        )

        for _ in 0..<12 {
            let result = try await client.execute(.status, timeoutSeconds: 2)
            #expect(result.sessionState == .online)
        }
    }

    @Test("process timeout starts and then terminates the actual child")
    func processTimeoutStopsStartedChild() async throws {
        let fixture = try makeLongRunningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = SZUNETCLIClient(
            executableURL: fixture.executable,
            requestIDFactory: { "process-timeout" }
        )
        let task = Task {
            try await client.execute(.status, timeoutSeconds: 1)
        }
        let processID = try await waitForProcessMarker(fixture.marker)
        let descendantID = try await waitForProcessMarker(fixture.descendantMarker)
        defer {
            terminateFixtureProcess(processID)
            terminateFixtureProcess(descendantID)
        }

        do {
            _ = try await task.value
            Issue.record("process transport unexpectedly ignored timeout")
        } catch let error as SZUNETAdapterError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected process timeout error type")
        }
        #expect(await waitUntilProcessStops(processID))
        #expect(await waitUntilProcessStops(descendantID))
    }

    @Test("process cancellation waits for startup and confirms termination")
    func processCancellationStopsStartedChild() async throws {
        let fixture = try makeLongRunningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = SZUNETCLIClient(
            executableURL: fixture.executable,
            requestIDFactory: { "process-cancel" }
        )
        let task = Task {
            try await client.execute(.status, timeoutSeconds: 5)
        }
        let processID = try await waitForProcessMarker(fixture.marker)
        let descendantID = try await waitForProcessMarker(fixture.descendantMarker)
        defer {
            terminateFixtureProcess(processID)
            terminateFixtureProcess(descendantID)
        }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("process transport unexpectedly ignored cancellation")
        } catch let error as SZUNETAdapterError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected process cancellation error type")
        }
        #expect(await waitUntilProcessStops(processID))
        #expect(await waitUntilProcessStops(descendantID))
    }

    @Test("timeout terminates descendants that outlive the direct child")
    func timeoutStopsExitedChildProcessGroup() async throws {
        let response = try wireJSONString(requestId: "exited-parent")
        let fixture = try makeExitedParentFixture(response: response)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let client = SZUNETCLIClient(
            executableURL: fixture.executable,
            requestIDFactory: { "exited-parent" }
        )
        let task = Task {
            try await client.execute(.status, timeoutSeconds: 1)
        }
        let descendantID = try await waitForProcessMarker(fixture.descendantMarker)
        defer { terminateFixtureProcess(descendantID) }

        do {
            _ = try await task.value
            Issue.record("inherited pipe unexpectedly bypassed the transport timeout")
        } catch let error as SZUNETAdapterError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected inherited-pipe timeout error type")
        }
        #expect(await waitUntilProcessStops(descendantID))
    }

    @Test("source target cannot regain authentication ownership")
    func sourceBoundaryIsEnforced() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("macos/Sources/SZUNETFeature")
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try sourceFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for forbidden in [
            "import SZUNetCore",
            "LoginCoordinator",
            "CampusProductRuntime",
            "saveCredentials",
            "SecureField",
            "CodexQuotaBar/Campus",
            "automaticLogin",
            "public let message",
            "public let timestamp",
        ] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains("process.arguments = [\"--json\"]"))

        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let targetMarker = ".target(\n            name: \"SZUNETFeature\""
        let start = try #require(manifest.range(of: targetMarker))
        let suffix = manifest[start.lowerBound...]
        let end = try #require(suffix.range(of: "        ),"))
        let target = String(suffix[..<end.upperBound])
        #expect(!target.contains("SZUNetCore"))
        #expect(target.contains("dependencies: []"))
    }
}

private enum FixtureError: Error {
    case invalidEncoding
    case processDidNotStart
}

private func encodeWireResult(
    schemaVersion: Int = 1,
    requestId: String,
    errorCode: String? = nil,
    message: String = "fixture",
    onlineDeviceCount: Int? = nil,
    onlineDeviceLimit: Int? = nil
) throws -> Data {
    try JSONEncoder().encode(
        SZUNETWireResult(
            schemaVersion: schemaVersion,
            requestId: requestId,
            outcome: .unchanged,
            provider: .dorm,
            networkContext: .dorm,
            sessionState: .online,
            errorCode: errorCode,
            retryable: false,
            automaticEnabled: true,
            ownerAppRunning: true,
            networkProbeEnabled: true,
            probeIntervalSeconds: 120,
            onlineDeviceCount: onlineDeviceCount,
            onlineDeviceLimit: onlineDeviceLimit,
            message: message,
            timestamp: "2026-07-28T00:00:00Z"
        )
    )
}

private func wireJSONString(requestId: String) throws -> String {
    let data = try encodeWireResult(requestId: requestId)
    guard let value = String(data: data, encoding: .utf8) else {
        throw FixtureError.invalidEncoding
    }
    return value
}

private func makeExecutableFixture(
    _ contents: String
) throws -> (directory: URL, executable: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-feature-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    let executable = directory.appendingPathComponent("fixture-cli")
    try contents.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )
    return (directory, executable)
}

private func makeLongRunningFixture() throws -> (
    directory: URL,
    executable: URL,
    marker: URL,
    descendantMarker: URL
) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-feature-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    let marker = directory.appendingPathComponent("started.pid")
    let descendantMarker = directory.appendingPathComponent("descendant.pid")
    let executable = directory.appendingPathComponent("fixture-cli")
    let script = """
    #!/bin/sh
    printf '%s\n' "$$" > \(shellQuoted(marker.path))
    trap '' TERM
    /bin/sh -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; exec /bin/sleep 30' fixture-child \(shellQuoted(descendantMarker.path)) &
    wait "$!"
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )
    return (directory, executable, marker, descendantMarker)
}

private func makeExitedParentFixture(response: String) throws -> (
    directory: URL,
    executable: URL,
    descendantMarker: URL
) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("szunet-feature-exited-parent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    let descendantMarker = directory.appendingPathComponent("descendant.pid")
    let executable = directory.appendingPathComponent("fixture-cli")
    let script = """
    #!/bin/sh
    cat >/dev/null
    /bin/sh -c 'trap "" TERM; printf "%s\\n" "$$" > "$1"; exec /bin/sleep 30' fixture-child \(shellQuoted(descendantMarker.path)) &
    while [ ! -s \(shellQuoted(descendantMarker.path)) ]; do /bin/sleep 0.01; done
    printf '%s\\n' '\(response)'
    exit 0
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )
    return (directory, executable, descendantMarker)
}

private func waitForProcessMarker(
    _ marker: URL,
    timeout: Duration = .seconds(3)
) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0 {
            return value
        }
        guard clock.now < deadline else { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.processDidNotStart
}

private func waitUntilProcessStops(
    _ processID: pid_t,
    timeout: Duration = .seconds(3)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if !processExists(processID) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !processExists(processID)
}

private func processExists(_ processID: pid_t) -> Bool {
    if Darwin.kill(processID, 0) == 0 { return true }
    return errno == EPERM
}

private func terminateFixtureProcess(_ processID: pid_t) {
    if processExists(processID) { _ = Darwin.kill(processID, SIGKILL) }
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
