public enum LoginActionOutcome: String, Codable, Equatable {
    case authenticated
    case loggedOut
    case unchanged
    case failed
    case uncertain
}

public struct LoginActionResult: Equatable {
    public var outcome: LoginActionOutcome
    public var title: String
    public var detail: String
    public var reason: String

    public init(
        outcome: LoginActionOutcome,
        title: String,
        detail: String = "",
        reason: String = ""
    ) {
        self.outcome = outcome
        self.title = title
        self.detail = detail
        self.reason = reason
    }

    public var isSuccess: Bool {
        switch outcome {
        case .authenticated, .loggedOut, .unchanged:
            return true
        case .failed, .uncertain:
            return false
        }
    }

    public var isAuthenticated: Bool {
        outcome == .authenticated
    }

    public var isLoggedOut: Bool {
        outcome == .loggedOut
    }

}
