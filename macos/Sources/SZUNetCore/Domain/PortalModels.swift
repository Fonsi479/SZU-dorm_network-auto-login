public enum PortalResultStatus: String, Equatable {
    case success
    case failed
    case unknown
}

public struct LoginResult: Equatable {
    public var status: PortalResultStatus
    public var reason: String
    public var httpStatus: Int
    public var sourceIP: String

    public init(
        status: PortalResultStatus,
        reason: String = "",
        httpStatus: Int = 0,
        sourceIP: String = ""
    ) {
        self.status = status
        self.reason = reason
        self.httpStatus = httpStatus
        self.sourceIP = sourceIP
    }
}

public struct LogoutResult: Equatable {
    public var status: PortalResultStatus
    public var reason: String

    public init(status: PortalResultStatus, reason: String = "") {
        self.status = status
        self.reason = reason
    }
}

public struct PortalTerminalParameters: Equatable {
    public var ip: String
    public var mac: String
    public var vlan: String
    public var wlanACIP: String
    public var wlanACName: String
    public var jsVersion: String
    public var pageURL: String

    public init(
        ip: String = "",
        mac: String = "000000000000",
        vlan: String = "0",
        wlanACIP: String = "",
        wlanACName: String = "",
        jsVersion: String = "4.1.3",
        pageURL: String = ""
    ) {
        self.ip = ip
        self.mac = mac
        self.vlan = vlan
        self.wlanACIP = wlanACIP
        self.wlanACName = wlanACName
        self.jsVersion = jsVersion
        self.pageURL = pageURL
    }
}
