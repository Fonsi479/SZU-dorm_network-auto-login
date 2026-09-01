public protocol DrCOMServicing: AnyObject {
    func login(username: String, password: String, knownSourceIP: String) async -> LoginResult
    func logout(username: String, knownSourceIP: String) async -> LogoutResult
    func isSessionOnline(username: String, sourceIP: String) async -> Bool?
    /// Returns the exact local session plus the account-wide Dorm device
    /// occupancy.  A default implementation keeps old integrations source
    /// compatible while real `DrCOMClient` instances provide the richer
    /// online-list evidence.
    func sessionStatus(username: String, sourceIP: String) async -> ProviderSessionResult
}

extension DrCOMClient: DrCOMServicing {}

public extension DrCOMServicing {
    func sessionStatus(username: String, sourceIP: String) async -> ProviderSessionResult {
        let online = await isSessionOnline(username: username, sourceIP: sourceIP)
        switch online {
        case .some(true):
            return ProviderSessionResult(
                state: .online,
                accountMatch: .matches,
                clientIP: sourceIP
            )
        case .some(false):
            return ProviderSessionResult(state: .offline, clientIP: sourceIP)
        case .none:
            return ProviderSessionResult(
                state: .unknown,
                clientIP: sourceIP,
                errorCode: "SESSION_UNKNOWN"
            )
        }
    }
}
