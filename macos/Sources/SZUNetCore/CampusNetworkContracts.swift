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

/// The Dorm portal enforces a fixed three-device account limit.  Keep this
/// policy in Core so every caller (manual login, automation, and the embedded
/// product) makes the same fail-closed decision without reading a local MAC.
public enum CampusOnlineDevicePolicy {
    public static let dormLimit = 3
}

public struct ProviderSessionResult: Equatable, Sendable {
    public var state: ProviderSessionState
    public var accountMatch: AccountMatch
    /// Whether the provider's authoritative online list contains the exact
    /// configured-account/source-IP record for this Mac. `nil` means the list
    /// was unavailable or could not be read safely.
    public var exactOnlineRecordPresent: Bool?
    public var clientIP: String
    public var product: String
    public var serverCode: String
    /// Number of distinct server-reported sessions for the selected account.
    /// `nil` means that the portal list was unavailable or could not be
    /// counted reliably.  It never represents a guessed local device count.
    public var onlineDeviceCount: Int?
    /// The provider's enforced online-device limit, when known.
    public var onlineDeviceLimit: Int?
    public var errorCode: String?
    public var retryable: Bool

    public init(
        state: ProviderSessionState,
        accountMatch: AccountMatch = .unknown,
        exactOnlineRecordPresent: Bool? = nil,
        clientIP: String = "",
        product: String = "",
        serverCode: String = "",
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil,
        errorCode: String? = nil,
        retryable: Bool = false
    ) {
        self.state = state
        self.accountMatch = accountMatch
        self.exactOnlineRecordPresent = exactOnlineRecordPresent
        self.clientIP = clientIP
        self.product = product
        self.serverCode = serverCode
        self.onlineDeviceCount = onlineDeviceCount
        self.onlineDeviceLimit = onlineDeviceLimit
        self.errorCode = errorCode
        self.retryable = retryable
    }

    public var isAtOnlineDeviceLimit: Bool {
        guard let count = onlineDeviceCount,
              let limit = onlineDeviceLimit,
              limit > 0 else { return false }
        return count >= limit
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
    /// Number of distinct server-reported sessions for the selected account.
    /// This remains `nil` whenever the portal could not provide a reliable
    /// count.
    public var onlineDeviceCount: Int?
    public var onlineDeviceLimit: Int?
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
        onlineDeviceCount: Int? = nil,
        onlineDeviceLimit: Int? = nil,
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
        self.onlineDeviceCount = onlineDeviceCount
        self.onlineDeviceLimit = onlineDeviceLimit
        self.errorCode = errorCode
        self.serverCode = serverCode
        self.retryable = retryable
        self.timestamp = timestamp
    }

    public static func blocked(_ providerID: CampusProviderID, _ code: String) -> Self {
        Self(outcome: .blocked, providerID: providerID, errorCode: code)
    }

    public static func blocked(
        _ providerID: CampusProviderID,
        _ code: String,
        session: ProviderSessionResult
    ) -> Self {
        Self(
            outcome: .blocked,
            providerID: providerID,
            sessionState: session.state,
            accountMatch: session.accountMatch,
            clientIP: session.clientIP,
            onlineDeviceCount: session.onlineDeviceCount,
            onlineDeviceLimit: session.onlineDeviceLimit,
            errorCode: code,
            retryable: session.retryable
        )
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
