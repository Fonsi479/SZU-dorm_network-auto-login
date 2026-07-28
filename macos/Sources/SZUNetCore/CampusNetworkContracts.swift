import Foundation

public enum CampusProviderID: String, Codable, Hashable, Sendable {
    case dorm
    case teaching
}

public enum ProviderSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case ambiguous
}

public enum ProbeConfidence: String, Codable, Equatable, Sendable {
    case verified
    case probable
    case unknown
}

public struct CampusNetworkContext: Equatable, Sendable {
    public var generation: UInt64
    public var portalURL: URL?
    public var portalHTML: String
    public var sourceInterface: String
    public var sourceIP: String
    public var sourceRouteBound: Bool
    public var dormPortalIdentityVerified: Bool
    public var teachingPortalIdentityVerified: Bool

    public init(
        generation: UInt64,
        portalURL: URL? = nil,
        portalHTML: String = "",
        sourceInterface: String = "",
        sourceIP: String = "",
        sourceRouteBound: Bool = false,
        dormPortalIdentityVerified: Bool = false,
        teachingPortalIdentityVerified: Bool = false
    ) {
        self.generation = generation
        self.portalURL = portalURL
        self.portalHTML = portalHTML
        self.sourceInterface = sourceInterface
        self.sourceIP = sourceIP
        self.sourceRouteBound = sourceRouteBound
        self.dormPortalIdentityVerified = dormPortalIdentityVerified
        self.teachingPortalIdentityVerified = teachingPortalIdentityVerified
    }
}

public struct ProviderProbe: Equatable, Sendable {
    public var providerID: CampusProviderID
    public var support: ProviderSupport
    public var confidence: ProbeConfidence
    public var portalIdentity: String
    public var sourceInterface: String
    public var sourceIP: String
    public var clientIP: String
    public var acid: String
    public var portalURL: URL?
    public var evidence: [String]
    public var expiresAt: Date?
    public var errorCode: String?

    public init(
        providerID: CampusProviderID,
        support: ProviderSupport,
        confidence: ProbeConfidence = .unknown,
        portalIdentity: String = "",
        sourceInterface: String = "",
        sourceIP: String = "",
        clientIP: String = "",
        acid: String = "",
        portalURL: URL? = nil,
        evidence: [String] = [],
        expiresAt: Date? = nil,
        errorCode: String? = nil
    ) {
        self.providerID = providerID
        self.support = support
        self.confidence = confidence
        self.portalIdentity = portalIdentity
        self.sourceInterface = sourceInterface
        self.sourceIP = sourceIP
        self.clientIP = clientIP
        self.acid = acid
        self.portalURL = portalURL
        self.evidence = evidence
        self.expiresAt = expiresAt
        self.errorCode = errorCode
    }

    public var isVerified: Bool {
        support == .supported && confidence == .verified && !sourceIP.isEmpty
    }
}

public enum ProviderSessionState: String, Codable, Equatable, Sendable {
    case online
    case offline
    case unknown
    case blocked
}

public enum AccountMatch: String, Codable, Equatable, Sendable {
    case matches
    case differs
    case unknown
}

public struct ProviderSessionResult: Equatable, Sendable {
    public var state: ProviderSessionState
    public var accountMatch: AccountMatch
    public var clientIP: String
    public var product: String
    public var serverCode: String
    public var errorCode: String?
    public var retryable: Bool

    public init(
        state: ProviderSessionState,
        accountMatch: AccountMatch = .unknown,
        clientIP: String = "",
        product: String = "",
        serverCode: String = "",
        errorCode: String? = nil,
        retryable: Bool = false
    ) {
        self.state = state
        self.accountMatch = accountMatch
        self.clientIP = clientIP
        self.product = product
        self.serverCode = serverCode
        self.errorCode = errorCode
        self.retryable = retryable
    }
}

public enum ProviderAuthOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case unchanged
    case failed
    case cancelled
    case blocked
}

public struct ProviderAuthResult: Equatable, Sendable {
    public var outcome: ProviderAuthOutcome
    public var providerID: CampusProviderID
    public var sessionState: ProviderSessionState
    public var accountMatch: AccountMatch
    public var clientIP: String
    public var acid: String
    public var errorCode: String?
    public var serverCode: String
    public var retryable: Bool
    public var timestamp: Date

    public init(
        outcome: ProviderAuthOutcome,
        providerID: CampusProviderID,
        sessionState: ProviderSessionState = .unknown,
        accountMatch: AccountMatch = .unknown,
        clientIP: String = "",
        acid: String = "",
        errorCode: String? = nil,
        serverCode: String = "",
        retryable: Bool = false,
        timestamp: Date = Date()
    ) {
        self.outcome = outcome
        self.providerID = providerID
        self.sessionState = sessionState
        self.accountMatch = accountMatch
        self.clientIP = clientIP
        self.acid = acid
        self.errorCode = errorCode
        self.serverCode = serverCode
        self.retryable = retryable
        self.timestamp = timestamp
    }

    public static func blocked(_ providerID: CampusProviderID, _ code: String) -> Self {
        Self(outcome: .blocked, providerID: providerID, errorCode: code)
    }
}

public struct CredentialHandle: @unchecked Sendable {
    fileprivate let secret: String

    public init(_ secret: String) {
        self.secret = secret
    }

    func withSecret<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(secret)
    }

    var value: String { secret }
}

public protocol CampusCredentialBroker: Sendable {
    func openCredential(for providerID: CampusProviderID, username: String) async throws -> CredentialHandle?
}

public protocol NetworkAuthProvider: Sendable {
    var providerID: CampusProviderID { get }
    func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe
    func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult
    func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult
    func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult
    func cancelPendingOperations(generation: UInt64) async
}
