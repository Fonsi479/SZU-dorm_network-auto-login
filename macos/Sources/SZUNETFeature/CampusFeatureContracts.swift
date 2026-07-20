import Foundation

public enum SZUNETEnvironment: String, Codable, Equatable, Sendable {
    case eligible
    case ineligible
    case unknown
}

public enum SZUNETPortalState: String, Codable, Equatable, Sendable {
    case authenticated
    case unauthenticated
    case checking
    case unknown
}

public enum SZUNETReachabilityState: String, Codable, Equatable, Sendable {
    case reachable
    case unreachable
    case checking
    case unknown
}

public struct SZUNETStatus: Codable, Equatable, Sendable {
    public var featureEnabled: Bool
    public var autoLoginEnabled: Bool
    public var environment: SZUNETEnvironment
    public var portal: SZUNETPortalState
    public var internet: SZUNETReachabilityState
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var errorCode: String?

    public init(
        featureEnabled: Bool = false,
        autoLoginEnabled: Bool = false,
        environment: SZUNETEnvironment = .unknown,
        portal: SZUNETPortalState = .unknown,
        internet: SZUNETReachabilityState = .unknown,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        errorCode: String? = nil
    ) {
        self.featureEnabled = featureEnabled
        self.autoLoginEnabled = autoLoginEnabled
        self.environment = environment
        self.portal = portal
        self.internet = internet
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.errorCode = errorCode
    }
}
