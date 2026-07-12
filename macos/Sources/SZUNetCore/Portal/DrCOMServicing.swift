public protocol DrCOMServicing: AnyObject {
    func login(username: String, password: String, knownSourceIP: String) async -> LoginResult
    func logout(username: String, knownSourceIP: String) async -> LogoutResult
    func isSessionOnline(username: String, sourceIP: String) async -> Bool?
}

extension DrCOMClient: DrCOMServicing {}
