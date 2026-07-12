import Foundation

public struct AppConfiguration: Codable, Equatable {
    public var schemaVersion: Int
    public var auth: AuthConfiguration
    public var user: UserConfiguration
    public var network: NetworkConfiguration
    public var security: SecurityConfiguration

    public init(
        schemaVersion: Int = 1,
        auth: AuthConfiguration = .default,
        user: UserConfiguration = .default,
        network: NetworkConfiguration = .default,
        security: SecurityConfiguration = .default
    ) {
        self.schemaVersion = schemaVersion
        self.auth = auth
        self.user = user
        self.network = network
        self.security = security
    }

    public static let `default` = AppConfiguration()

    public func validatedForPortalAction() throws -> AppConfiguration {
        let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != UserConfiguration.placeholder else {
            throw SZUNetError.configuration("请先设置校园网账号。")
        }
        guard let loginURL = URL(string: auth.loginURL),
              loginURL.scheme == "http",
              loginURL.host != nil else {
            throw SZUNetError.configuration("登录地址必须是有效的 HTTP 地址。")
        }
        guard auth.timeoutSeconds > 0 else {
            throw SZUNetError.configuration("登录超时必须是正整数。")
        }
        return self
    }

    public func validatedForLogin() throws -> AppConfiguration {
        _ = try validatedForPortalAction()
        guard !network.gatewayHosts.isEmpty else {
            throw SZUNetError.configuration("至少需要配置一个宿舍区网关。")
        }
        guard network.testURLs.count >= 2 else {
            throw SZUNetError.configuration("至少需要配置两个联网检测地址。")
        }
        for value in network.campusSourceNetworks where !IPv4CIDR.isValid(value) {
            throw SZUNetError.configuration("校园网源 IP 网段格式无效：\(value)")
        }
        return self
    }
}

public struct AuthConfiguration: Codable, Equatable {
    public var loginURL: String
    public var logoutURL: String
    public var logoutPageURL: String
    public var unbindURL: String
    public var callback: String
    public var logoutCallback: String
    public var logoutJSVersion: String
    public var loginMethod: String
    public var accountPrefix: String
    public var timeoutSeconds: Int

    public init(
        loginURL: String,
        logoutURL: String = "",
        logoutPageURL: String = "",
        unbindURL: String = "",
        callback: String = "dr1003",
        logoutCallback: String = "dr1004",
        logoutJSVersion: String = "4.1.3",
        loginMethod: String = "1",
        accountPrefix: String = ",1,",
        timeoutSeconds: Int = 8
    ) {
        self.loginURL = loginURL
        self.logoutURL = logoutURL
        self.logoutPageURL = logoutPageURL
        self.unbindURL = unbindURL
        self.callback = callback
        self.logoutCallback = logoutCallback
        self.logoutJSVersion = logoutJSVersion
        self.loginMethod = loginMethod
        self.accountPrefix = accountPrefix
        self.timeoutSeconds = timeoutSeconds
    }

    public static let `default` = AuthConfiguration(
        loginURL: "http://172.30.255.42:801/eportal/portal/login"
    )
}

public struct UserConfiguration: Codable, Equatable {
    public static let placeholder = "你的校园卡号，不要写密码"
    public var username: String

    public init(username: String = placeholder) {
        self.username = username
    }

    public static let `default` = UserConfiguration()
}

public struct NetworkConfiguration: Codable, Equatable {
    public var gatewayHosts: [String]
    public var campusWiFiNames: [String]
    public var campusSourceNetworks: [String]
    public var timeoutSeconds: Int
    public var maxTestURLs: Int
    public var testURLs: [String]

    public init(
        gatewayHosts: [String] = ["172.30.255.42"],
        campusWiFiNames: [String] = ["SZU_CTC&CMCC"],
        campusSourceNetworks: [String] = ["172.16.0.0/12"],
        timeoutSeconds: Int = 3,
        maxTestURLs: Int = 3,
        testURLs: [String] = [
            "http://captive.apple.com/hotspot-detect.html",
            "http://www.baidu.com/",
            "https://www.baidu.com/",
        ]
    ) {
        self.gatewayHosts = gatewayHosts
        self.campusWiFiNames = campusWiFiNames
        self.campusSourceNetworks = campusSourceNetworks
        self.timeoutSeconds = timeoutSeconds
        self.maxTestURLs = maxTestURLs
        self.testURLs = testURLs
    }

    public static let `default` = NetworkConfiguration()
}

public struct SecurityConfiguration: Codable, Equatable {
    public enum PasswordSource: String, Codable {
        case keychain
        case environment = "env"
        case privateFile = "private_file"
    }

    public var passwordSource: PasswordSource
    public var passwordEnvironmentName: String
    public var privateFilePath: String
    public var keychainService: String
    public var keychainAccount: String

    public init(
        passwordSource: PasswordSource = .keychain,
        passwordEnvironmentName: String = "SZU_NET_PASSWORD",
        privateFilePath: String = "~/.szu-netlogin/password.yaml",
        keychainService: String = "szu-netlogin",
        keychainAccount: String = ""
    ) {
        self.passwordSource = passwordSource
        self.passwordEnvironmentName = passwordEnvironmentName
        self.privateFilePath = privateFilePath
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public static let `default` = SecurityConfiguration()

    private enum CodingKeys: String, CodingKey {
        case passwordSource
        case passwordEnvironmentName
        case privateFilePath
        case keychainService
        case keychainAccount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        passwordSource = try values.decodeIfPresent(
            PasswordSource.self,
            forKey: .passwordSource
        ) ?? .keychain
        passwordEnvironmentName = try values.decodeIfPresent(
            String.self,
            forKey: .passwordEnvironmentName
        ) ?? "SZU_NET_PASSWORD"
        privateFilePath = try values.decodeIfPresent(
            String.self,
            forKey: .privateFilePath
        ) ?? "~/.szu-netlogin/password.yaml"
        keychainService = try values.decodeIfPresent(
            String.self,
            forKey: .keychainService
        ) ?? "szu-netlogin"
        keychainAccount = try values.decodeIfPresent(
            String.self,
            forKey: .keychainAccount
        ) ?? ""
    }
}
