public enum CampusSessionState: String, Codable, Equatable {
    case online
    case offline
    case unknown
}

public struct NetworkStatus: Equatable {
    public var gatewayReachable: Bool
    public var campusInternetOK: Bool
    public var gatewayHost: String
    public var sourceIP: String
    public var gatewayReason: String
    public var internetReason: String
    public var internetPortalRedirect: Bool
    public var campusSessionState: CampusSessionState

    public init(
        gatewayReachable: Bool,
        campusInternetOK: Bool,
        gatewayHost: String = "",
        sourceIP: String = "",
        gatewayReason: String = "",
        internetReason: String = "",
        internetPortalRedirect: Bool = false,
        campusSessionState: CampusSessionState = .unknown
    ) {
        self.gatewayReachable = gatewayReachable
        self.campusInternetOK = campusInternetOK
        self.gatewayHost = gatewayHost
        self.sourceIP = sourceIP
        self.gatewayReason = gatewayReason
        self.internetReason = internetReason
        self.internetPortalRedirect = internetPortalRedirect
        self.campusSessionState = campusSessionState
    }
}

public struct NetworkEnvironment: Equatable {
    public var label: String
    public var isDormNetwork: Bool
    public var autoLoginAvailable: Bool
    public var wifiSSID: String
    public var sourceIP: String
    public var reason: String

    public init(
        label: String,
        isDormNetwork: Bool,
        autoLoginAvailable: Bool,
        wifiSSID: String = "",
        sourceIP: String = "",
        reason: String = ""
    ) {
        self.label = label
        self.isDormNetwork = isDormNetwork
        self.autoLoginAvailable = autoLoginAvailable
        self.wifiSSID = wifiSSID
        self.sourceIP = sourceIP
        self.reason = reason
    }
}
