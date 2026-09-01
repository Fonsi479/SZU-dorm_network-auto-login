import AppKit
import Darwin
import Foundation
import SZUNetCore

@main
struct SZUCampusNetctl {
    static func main() async {
        let response: CampusCLIResponse
        if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
            let request = CampusCLIRequest(requestId: "offline-self-test", command: .status)
            let data = try? JSONEncoder().encode(request)
            response = await CampusCLIProcessor.process(
                data ?? Data(),
                handler: OfflineSelfTestHandler()
            )
        } else if CommandLine.arguments == [CommandLine.arguments[0], "--json"] {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            do {
                let accessMode = try CampusContainingApplication.credentialAccessMode()
                let controller = try CampusProductRuntime.make(credentialAccessMode: accessMode)
                response = await CampusCLIProcessor.process(
                    input,
                    handler: LiveCampusCLIHandler(
                        controller: controller,
                        automationStore: CampusAutomationStore()
                    )
                )
            } catch {
                response = .blocked(requestId: "configuration-error", code: "CFG_INVALID")
            }
        } else {
            response = .blocked(requestId: "invalid-arguments", code: "CFG_INVALID")
        }
        try? FileHandle.standardOutput.write(contentsOf: CampusCLIProcessor.encode(response))
        exit(CampusCLIProcessor.exitCode(for: response))
    }
}

private actor LiveCampusCLIHandler: CampusCLIHandling {
    let controller: CampusProductController
    let automationStore: CampusAutomationStore

    init(controller: CampusProductController, automationStore: CampusAutomationStore) {
        self.controller = controller
        self.automationStore = automationStore
    }

    func handle(_ request: CampusCLIRequest) async -> CampusCLIResponse {
        switch request.command {
        case .status:
            return await snapshotResponse(request, snapshot: await controller.refresh())
        case .check:
            return await snapshotResponse(request, snapshot: await controller.refresh())
        case .login:
            let result = await controller.login(
                requestedProvider: request.provider.providerID,
                automatic: false
            )
            return await actionResponse(request, result: result)
        case .forceLogin:
            guard request.interactive, request.provider != .teaching else {
                return .blocked(
                    requestId: request.requestId,
                    code: request.provider == .teaching
                        ? "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED"
                        : "AUTH_NOT_CONFIRMED",
                    provider: request.provider.rawValue
                )
            }
            let result = await controller.forceLogin(
                requestedProvider: request.provider.providerID
            )
            return await actionResponse(request, result: result)
        case .logout:
            let provider: CampusProviderID
            if let requested = request.provider.providerID {
                provider = requested
            } else {
                let snapshot = await controller.refresh()
                switch snapshot.category {
                case .dorm: provider = .dorm
                case .teaching: provider = .teaching
                case .ambiguous, .nonCampus, .unknown:
                    return CampusCLIResponse(
                        requestId: request.requestId,
                        outcome: .blocked,
                        provider: "auto",
                        networkContext: snapshot.category.rawValue,
                        sessionState: .blocked,
                        errorCode: snapshot.category == .ambiguous
                            ? "ENV_AMBIGUOUS"
                            : "ENV_NON_CAMPUS",
                        message: snapshot.category == .ambiguous
                            ? "ENV_AMBIGUOUS"
                            : "ENV_NON_CAMPUS",
                        sanitizedDiagnostics: snapshot
                    )
                }
            }
            return await actionResponse(
                request,
                result: await controller.logout(providerID: provider)
            )
        case .pause:
            do {
                try await controller.pause()
                return await snapshotResponse(
                    request,
                    snapshot: await controller.currentSnapshot(),
                    outcome: .succeeded
                )
            } catch {
                return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
            }
        case .resume:
            do {
                try await controller.resume()
                return await snapshotResponse(
                    request,
                    snapshot: await controller.currentSnapshot(),
                    outcome: .succeeded
                )
            } catch {
                return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
            }
        case .enableProbe:
            return await updateProbePreferences(request, enabled: true)
        case .disableProbe:
            return await updateProbePreferences(request, enabled: false)
        case .probeEvery30Seconds:
            return await updateProbePreferences(request, intervalSeconds: 30)
        case .probeEvery60Seconds:
            return await updateProbePreferences(request, intervalSeconds: 60)
        case .probeEvery120Seconds:
            return await updateProbePreferences(request, intervalSeconds: 120)
        case .probeEvery300Seconds:
            return await updateProbePreferences(request, intervalSeconds: 300)
        case .openSettings:
            guard await CampusOwnerApplicationBridge.openSettings() else {
                return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
            }
            return await snapshotResponse(
                request,
                snapshot: await controller.currentSnapshot(),
                outcome: .succeeded
            )
        case .diagnostics:
            return await snapshotResponse(request, snapshot: await controller.refresh())
        }
    }

    private func actionResponse(
        _ request: CampusCLIRequest,
        result: ProviderAuthResult
    ) async -> CampusCLIResponse {
        let snapshot = await controller.currentSnapshot()
        return CampusCLIResponse(
            requestId: request.requestId,
            outcome: result.outcome,
            provider: result.providerID.rawValue,
            networkContext: snapshot.category.rawValue,
            sessionState: result.sessionState,
            onlineDeviceCount: result.onlineDeviceCount ?? snapshot.onlineDeviceCount,
            onlineDeviceLimit: result.onlineDeviceLimit ?? snapshot.onlineDeviceLimit,
            errorCode: result.errorCode,
            retryable: result.retryable,
            automaticEnabled: snapshot.automaticEnabled,
            ownerAppRunning: ownershipSnapshot?.ownerRunning ?? false,
            networkProbeEnabled: probePreferences.enabled,
            probeIntervalSeconds: probePreferences.intervalSeconds,
            message: result.errorCode ?? result.outcome.rawValue,
            sanitizedDiagnostics: snapshot
        )
    }

    private func snapshotResponse(
        _ request: CampusCLIRequest,
        snapshot: CampusProductSnapshot,
        outcome: ProviderAuthOutcome = .unchanged
    ) async -> CampusCLIResponse {
        let state: ProviderSessionState = switch request.provider {
        case .dorm: ProviderSessionState(rawValue: snapshot.dorm.lifecycle) ?? .unknown
        case .teaching: ProviderSessionState(rawValue: snapshot.teaching.lifecycle) ?? .unknown
        case .auto:
            switch snapshot.category {
            case .dorm: ProviderSessionState(rawValue: snapshot.dorm.lifecycle) ?? .unknown
            case .teaching: ProviderSessionState(rawValue: snapshot.teaching.lifecycle) ?? .unknown
            case .ambiguous, .nonCampus, .unknown: .unknown
            }
        }
        return CampusCLIResponse(
            requestId: request.requestId,
            outcome: outcome,
            provider: request.provider.rawValue,
            networkContext: snapshot.category.rawValue,
            sessionState: state,
            onlineDeviceCount: snapshot.onlineDeviceCount,
            onlineDeviceLimit: snapshot.onlineDeviceLimit,
            errorCode: snapshot.lastErrorCode,
            automaticEnabled: snapshot.automaticEnabled,
            ownerAppRunning: ownershipSnapshot?.ownerRunning ?? false,
            networkProbeEnabled: probePreferences.enabled,
            probeIntervalSeconds: probePreferences.intervalSeconds,
            message: snapshot.lastErrorCode ?? outcome.rawValue,
            sanitizedDiagnostics: snapshot
        )
    }

    private func updateProbePreferences(
        _ request: CampusCLIRequest,
        enabled: Bool? = nil,
        intervalSeconds: Int? = nil
    ) async -> CampusCLIResponse {
        do {
            let current = try automationStore.load()
            _ = try automationStore.updateProbe(
                enabled: enabled ?? current.networkProbeEnabled,
                intervalSeconds: intervalSeconds ?? current.probeIntervalSeconds
            )
        } catch {
            return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
        }
        return await snapshotResponse(
            request,
            snapshot: await controller.currentSnapshot(),
            outcome: .succeeded
        )
    }

    private var probePreferences: (enabled: Bool, intervalSeconds: Int) {
        guard let configuration = try? automationStore.load() else {
            return (
                false,
                CampusAutomationPreferences.defaultProbeIntervalSeconds
            )
        }
        return (configuration.networkProbeEnabled, configuration.probeIntervalSeconds)
    }

    private var ownershipSnapshot: CampusAutomationOwnershipSnapshot? {
        try? automationStore.ownershipSnapshot(for: CampusContainingApplication.cliHostID)
    }
}

@MainActor
private enum CampusOwnerApplicationBridge {
    private static let bundleIdentifier = "com.szu-netlogin.dorm-login"
    private static let settingsURL = URL(string: "szunet://settings")!

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }

    static func openSettings() async -> Bool {
        if isRunning {
            return NSWorkspace.shared.open(settingsURL)
        }
        guard let applicationURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--open-settings"]
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: error == nil && application != nil)
            }
        }
    }

    private static var applicationURL: URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let containingBundle = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if containingBundle.pathExtension == "app",
           Bundle(url: containingBundle)?.bundleIdentifier == bundleIdentifier {
            return containingBundle
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
    }
}

private enum CampusContainingApplication {
    static let cliHostID = "com.szu-netlogin.dorm-login"
    private static let credentialModeKey = "SZUNETCredentialMode"
    private static let accessGroupKey = "SZUNETKeychainAccessGroup"

    static func credentialAccessMode() throws -> CampusCredentialAccessMode {
        guard let bundle = containingBundle else { return .local }
        let rawMode = (bundle.object(forInfoDictionaryKey: credentialModeKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "local"
        switch rawMode {
        case "local":
            return .local
        case "shared":
            guard let accessGroup = (bundle.object(forInfoDictionaryKey: accessGroupKey) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !accessGroup.isEmpty else {
                throw SZUNetError.configuration("shared credential mode 缺少 Keychain access group。")
            }
            return .shared(
                accessGroup: accessGroup,
                legacyLocations: [.init(accessGroup: nil)]
            )
        default:
            throw SZUNetError.configuration("不支持的 SZUNET credential mode。")
        }
    }

    private static var containingBundle: Bundle? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let applicationURL = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard applicationURL.pathExtension == "app" else { return nil }
        return Bundle(url: applicationURL)
    }
}

private actor OfflineSelfTestHandler: CampusCLIHandling {
    func handle(_ request: CampusCLIRequest) async -> CampusCLIResponse {
        CampusCLIResponse(
            requestId: request.requestId,
            outcome: .unchanged,
            provider: request.provider.rawValue,
            networkContext: "unknown",
            sessionState: .unknown,
            message: "offline-self-test"
        )
    }
}
