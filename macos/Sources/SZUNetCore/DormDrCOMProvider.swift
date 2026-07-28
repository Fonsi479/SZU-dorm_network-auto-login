import Foundation

public actor DormDrCOMProvider: NetworkAuthProvider {
    public let providerID = CampusProviderID.dorm
    private let client: DrCOMServicing

    public init(client: DrCOMServicing) {
        self.client = client
    }

    public func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe {
        guard context.dormPortalIdentityVerified else {
            return ProviderProbe(
                providerID: providerID,
                support: .unsupported,
                errorCode: "ENV_PORTAL_IDENTITY_UNVERIFIED"
            )
        }
        guard context.sourceRouteBound, !context.sourceIP.isEmpty else {
            return ProviderProbe(
                providerID: providerID,
                support: .unsupported,
                errorCode: "ENV_SOURCE_ROUTE_UNVERIFIED"
            )
        }
        return ProviderProbe(
            providerID: providerID,
            support: .supported,
            confidence: .verified,
            portalIdentity: "dorm-drcom",
            sourceInterface: context.sourceInterface,
            sourceIP: context.sourceIP,
            clientIP: context.sourceIP,
            evidence: ["portal_identity_verified", "source_route_bound"]
        )
    }

    public func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult {
        guard probe.isVerified else {
            return ProviderSessionResult(state: .blocked, errorCode: "ENV_SOURCE_ROUTE_UNVERIFIED")
        }
        let online = await client.isSessionOnline(username: username, sourceIP: probe.sourceIP)
        if online == true {
            return ProviderSessionResult(
                state: .online,
                accountMatch: .matches,
                clientIP: probe.sourceIP
            )
        }
        if online == false { return ProviderSessionResult(state: .offline, clientIP: probe.sourceIP) }
        return ProviderSessionResult(state: .unknown, errorCode: "SESSION_UNKNOWN")
    }

    public func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult {
        guard !Task.isCancelled, context.generation >= 0 else {
            return ProviderAuthResult(outcome: .cancelled, providerID: providerID, errorCode: "OPERATION_CANCELLED")
        }
        let result = await client.login(
            username: username,
            password: credential.value,
            knownSourceIP: probe.sourceIP
        )
        guard !Task.isCancelled else {
            return ProviderAuthResult(outcome: .cancelled, providerID: providerID, errorCode: "OPERATION_CANCELLED")
        }
        guard result.status == .success else {
            return ProviderAuthResult(
                outcome: result.status == .unknown ? .blocked : .failed,
                providerID: providerID,
                clientIP: probe.sourceIP,
                errorCode: result.reason.isEmpty ? "INTERNAL_ERROR" : result.reason,
                retryable: result.reason == "request_exception"
            )
        }
        let confirmed = await client.isSessionOnline(username: username, sourceIP: probe.sourceIP)
        guard confirmed == true else {
            return ProviderAuthResult(
                outcome: .failed,
                providerID: providerID,
                sessionState: confirmed == false ? .offline : .unknown,
                clientIP: probe.sourceIP,
                errorCode: "AUTH_NOT_CONFIRMED",
                retryable: confirmed == false
            )
        }
        return ProviderAuthResult(
            outcome: .succeeded,
            providerID: providerID,
            sessionState: .online,
            accountMatch: .matches,
            clientIP: probe.sourceIP
        )
    }

    public func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        let result = await client.logout(username: username, knownSourceIP: probe.sourceIP)
        return ProviderAuthResult(
            outcome: result.status == .success ? .succeeded : .failed,
            providerID: providerID,
            sessionState: result.status == .success ? .offline : .unknown,
            clientIP: probe.sourceIP,
            errorCode: result.status == .success ? nil : result.reason
        )
    }

    public func cancelPendingOperations(generation: UInt64) async {}
}
