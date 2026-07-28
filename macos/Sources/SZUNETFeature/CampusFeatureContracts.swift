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

public enum SZUNETNetworkCategory: String, Codable, Equatable, Sendable {
    case dorm
    case teaching
    case ambiguous
    case nonCampus
    case unknown
}

public struct SZUNETProviderStatus: Codable, Equatable, Sendable {
    public var provider: String
    public var enabled: Bool
    public var accountLabel: String
    public var lifecycle: String
    public var errorCode: String?

    public init(
        provider: String,
        enabled: Bool,
        accountLabel: String,
        lifecycle: String,
        errorCode: String? = nil
    ) {
        self.provider = provider
        self.enabled = enabled
        self.accountLabel = accountLabel
        self.lifecycle = lifecycle
        self.errorCode = errorCode
    }
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
    public var networkCategory: SZUNETNetworkCategory?
    public var providers: [SZUNETProviderStatus]?

    public init(
        featureEnabled: Bool = false,
        autoLoginEnabled: Bool = false,
        environment: SZUNETEnvironment = .unknown,
        portal: SZUNETPortalState = .unknown,
        internet: SZUNETReachabilityState = .unknown,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        errorCode: String? = nil,
        networkCategory: SZUNETNetworkCategory? = nil,
        providers: [SZUNETProviderStatus]? = nil
    ) {
        self.featureEnabled = featureEnabled
        self.autoLoginEnabled = autoLoginEnabled
        self.environment = environment
        self.portal = portal
        self.internet = internet
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.errorCode = errorCode
        self.networkCategory = networkCategory
        self.providers = providers
    }
}
