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
        var result = await client.sessionStatus(
            username: username,
            sourceIP: probe.sourceIP
        )
        if result.state == .offline,
           result.onlineDeviceCount.map({ $0 >= CampusOnlineDevicePolicy.dormLimit }) == true {
            result.errorCode = "AUTH_DEVICE_LIMIT"
        }
        // The lower-level client owns portal parsing and account-wide device
        // counting.  Keep a defensive source IP fallback for legacy test
        // doubles that only return a boolean-derived status.
        if result.clientIP.isEmpty {
            var enriched = result
            enriched.clientIP = probe.sourceIP
            return enriched
        }
        return result
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
            let code = DormDrCOMErrorCode.login(result.reason)
            return ProviderAuthResult(
                outcome: result.status == .unknown ? .blocked : .failed,
                providerID: providerID,
                clientIP: probe.sourceIP,
                errorCode: code,
                retryable: code == "NET_TIMEOUT"
            )
        }
        // Refresh the richer session fact exactly once after a successful
        // portal response.  This carries the server's account-wide device
        // occupancy into the public result without ever reading a local MAC.
        let confirmed = await client.sessionStatus(
            username: username,
            sourceIP: probe.sourceIP
        )
        guard confirmed.state == .online,
              confirmed.accountMatch == .matches else {
            return ProviderAuthResult(
                outcome: .failed,
                providerID: providerID,
                sessionState: confirmed.state,
                accountMatch: confirmed.accountMatch,
                clientIP: probe.sourceIP,
                onlineDeviceCount: confirmed.onlineDeviceCount,
                onlineDeviceLimit: confirmed.onlineDeviceLimit,
                errorCode: "AUTH_NOT_CONFIRMED",
                retryable: confirmed.state == .offline
            )
        }
        return ProviderAuthResult(
            outcome: .succeeded,
            providerID: providerID,
            sessionState: .online,
            accountMatch: .matches,
            clientIP: probe.sourceIP,
            onlineDeviceCount: confirmed.onlineDeviceCount,
            onlineDeviceLimit: confirmed.onlineDeviceLimit
        )
    }

    public func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        let result = await client.logout(username: username, knownSourceIP: probe.sourceIP)
        let code = result.status == .success ? nil : DormDrCOMErrorCode.logout(result.reason)
        return ProviderAuthResult(
            outcome: result.status == .success ? .succeeded : .failed,
            providerID: providerID,
            sessionState: result.status == .success ? .offline : .unknown,
            clientIP: probe.sourceIP,
            errorCode: code,
            retryable: code == "NET_TIMEOUT"
        )
    }

    public func cancelPendingOperations(generation: UInt64) async {}
}

enum DormDrCOMErrorCode {
    static func login(_ reason: String) -> String {
        switch reason {
        case "password_error": "AUTH_BAD_PASSWORD"
        case "gateway_unreachable", "request_exception", "server_response_uncertain": "NET_TIMEOUT"
        case "portal_interface_changed": "ENV_PORTAL_IDENTITY_UNVERIFIED"
        case "login_not_confirmed", "server_failed": "AUTH_NOT_CONFIRMED"
        case "session_verification_unavailable": "SESSION_UNKNOWN"
        case "request_cancelled": "OPERATION_CANCELLED"
        default: "INTERNAL_ERROR"
        }
    }

    static func logout(_ reason: String) -> String {
        switch reason {
        case "logout_url_not_configured": "CFG_INVALID"
        case "terminal_ip_not_found": "ENV_SOURCE_ROUTE_UNVERIFIED"
        case "logout_not_confirmed": "SESSION_ONLINE"
        case "session_state_unknown", "session_verification_unavailable": "SESSION_UNKNOWN"
        case "gateway_unreachable", "request_exception": "NET_TIMEOUT"
        case "request_cancelled": "OPERATION_CANCELLED"
        default: "INTERNAL_ERROR"
        }
    }
}
