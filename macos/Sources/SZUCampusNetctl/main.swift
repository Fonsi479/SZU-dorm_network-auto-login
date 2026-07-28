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
                let controller = try CampusProductRuntime.make()
                response = await CampusCLIProcessor.process(
                    input,
                    handler: LiveCampusCLIHandler(controller: controller)
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

    init(controller: CampusProductController) {
        self.controller = controller
    }

    func handle(_ request: CampusCLIRequest) async -> CampusCLIResponse {
        switch request.command {
        case .status:
            return snapshotResponse(request, snapshot: await controller.currentSnapshot())
        case .check:
            return snapshotResponse(request, snapshot: await controller.refresh())
        case .login:
            let result = await controller.login(
                requestedProvider: request.provider.providerID,
                automatic: false
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
                return snapshotResponse(
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
                return snapshotResponse(
                    request,
                    snapshot: await controller.currentSnapshot(),
                    outcome: .succeeded
                )
            } catch {
                return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
            }
        case .openSettings:
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.szu-netlogin.dorm-login"
            ) else {
                return .blocked(requestId: request.requestId, code: "INTERNAL_ERROR")
            }
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.arguments = ["--open-settings"]
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: openConfiguration,
                completionHandler: nil
            )
            return snapshotResponse(
                request,
                snapshot: await controller.currentSnapshot(),
                outcome: .succeeded
            )
        case .diagnostics:
            return snapshotResponse(request, snapshot: await controller.currentSnapshot())
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
            errorCode: result.errorCode,
            retryable: result.retryable,
            message: result.errorCode ?? result.outcome.rawValue,
            sanitizedDiagnostics: snapshot
        )
    }

    private func snapshotResponse(
        _ request: CampusCLIRequest,
        snapshot: CampusProductSnapshot,
        outcome: ProviderAuthOutcome = .unchanged
    ) -> CampusCLIResponse {
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
            errorCode: snapshot.lastErrorCode,
            message: snapshot.lastErrorCode ?? outcome.rawValue,
            sanitizedDiagnostics: snapshot
        )
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
