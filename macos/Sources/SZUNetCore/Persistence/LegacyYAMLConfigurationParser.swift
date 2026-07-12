import Foundation

public enum LegacyYAMLConfigurationParser {
    public static func parse(_ text: String) throws -> AppConfiguration {
        let document = try LegacyYAMLDocumentParser.parse(text)
        var configuration = AppConfiguration.default

        if let auth = document["auth"] {
            configuration.auth.loginURL = string(auth["login_url"], default: configuration.auth.loginURL)
            configuration.auth.logoutURL = string(auth["logout_url"])
            configuration.auth.logoutPageURL = string(auth["logout_page_url"])
            configuration.auth.unbindURL = string(auth["unbind_url"])
            configuration.auth.callback = string(auth["callback"], default: configuration.auth.callback)
            configuration.auth.logoutCallback = string(
                auth["logout_callback"],
                default: configuration.auth.logoutCallback
            )
            configuration.auth.logoutJSVersion = string(
                auth["logout_js_version"],
                default: configuration.auth.logoutJSVersion
            )
            configuration.auth.loginMethod = string(
                auth["login_method"],
                default: configuration.auth.loginMethod
            )
            configuration.auth.accountPrefix = string(
                auth["account_prefix"],
                default: configuration.auth.accountPrefix
            )
            configuration.auth.timeoutSeconds = integer(
                auth["timeout_seconds"],
                default: configuration.auth.timeoutSeconds
            )
        }

        if let user = document["user"] {
            configuration.user.username = string(
                user["username"],
                default: configuration.user.username
            )
        }

        if let network = document["network"] {
            configuration.network.gatewayHosts = strings(
                network["dorm_gateway_hosts"],
                default: configuration.network.gatewayHosts
            )
            configuration.network.campusWiFiNames = strings(
                network["campus_wifi_names"],
                default: configuration.network.campusWiFiNames
            )
            configuration.network.campusSourceNetworks = strings(
                network["campus_source_networks"],
                default: configuration.network.campusSourceNetworks
            )
            configuration.network.timeoutSeconds = integer(
                network["timeout_seconds"],
                default: configuration.network.timeoutSeconds
            )
            configuration.network.maxTestURLs = integer(
                network["max_test_urls"],
                default: configuration.network.maxTestURLs
            )
            configuration.network.testURLs = strings(
                network["test_urls"],
                default: configuration.network.testURLs
            )
        }

        if let security = document["security"] {
            let legacySource = string(security["password_source"], default: "keychain")
            configuration.security.passwordSource = SecurityConfiguration.PasswordSource(
                rawValue: legacySource
            ) ?? .keychain
            configuration.security.passwordEnvironmentName = string(
                security["password_env_name"],
                default: configuration.security.passwordEnvironmentName
            )
            configuration.security.privateFilePath = string(
                security["password_file"],
                default: configuration.security.privateFilePath
            )
            configuration.security.keychainService = string(
                security["keychain_service"],
                default: configuration.security.keychainService
            )
            configuration.security.keychainAccount = string(security["keychain_account"])
        }

        return configuration
    }

    private static func string(
        _ value: LegacyYAMLValue?,
        default defaultValue: String = ""
    ) -> String {
        guard case .scalar(let result)? = value else { return defaultValue }
        return result
    }

    private static func strings(
        _ value: LegacyYAMLValue?,
        default defaultValue: [String]
    ) -> [String] {
        guard case .list(let result)? = value, !result.isEmpty else { return defaultValue }
        return result
    }

    private static func integer(
        _ value: LegacyYAMLValue?,
        default defaultValue: Int
    ) -> Int {
        guard case .scalar(let result)? = value, let integer = Int(result) else {
            return defaultValue
        }
        return integer
    }
}
