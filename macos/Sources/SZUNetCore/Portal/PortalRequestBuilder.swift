import Foundation

enum PortalRequestBuilder {
    static func login(
        configuration: AppConfiguration,
        username: String,
        password: String,
        sourceIP: String,
        macAddress: String = ""
    ) -> [String: String] {
        var values = [
            "callback": configuration.auth.callback,
            "login_method": configuration.auth.loginMethod,
            "user_account": configuration.auth.accountPrefix + username,
            "user_password": password,
        ]
        if !sourceIP.isEmpty { values["wlan_user_ip"] = sourceIP }
        // The deployed page reports an all-zero MAC during normal login. Do not
        // substitute macOS's interface address unless a caller explicitly asks.
        if !macAddress.isEmpty { values["wlan_user_mac"] = macAddress.uppercased() }
        return values
    }

    static func unbind(
        configuration: AppConfiguration,
        account: String,
        fact: PortalSessionFact,
        jsVersion: String,
        stripISPSuffix: Bool
    ) -> [String: String] {
        var wireAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripISPSuffix, let suffix = wireAccount.lastIndex(of: "@") {
            wireAccount = String(wireAccount[..<suffix])
        }
        return [
            "callback": configuration.auth.callback.isEmpty ? "dr1003" : configuration.auth.callback,
            "user_account": wireAccount,
            "wlan_user_mac": fact.mac.uppercased(),
            "wlan_user_ip": IPv4CIDR.portalInteger(fact.ip),
            "jsVersion": jsVersion.isEmpty ? "4.1.3" : jsVersion,
        ]
    }

    static func portalLogout(
        configuration: AppConfiguration,
        terminal: PortalTerminalParameters,
        runtime: PortalRuntimeSettings? = nil
    ) -> [String: String] {
        let loginMethod = runtime.map { String($0.loginMethod) } ?? configuration.auth.loginMethod
        let acLogout = runtime.map { String($0.acLogout) } ?? "0"
        let registerMode = runtime.map { String($0.registerMode) } ?? "1"
        return [
            "callback": configuration.auth.logoutCallback.isEmpty
                ? "dr1004" : configuration.auth.logoutCallback,
            "login_method": loginMethod,
            "user_account": "drcom",
            "user_password": "123",
            "ac_logout": acLogout,
            "register_mode": registerMode,
            "wlan_user_ip": terminal.ip,
            "wlan_user_ipv6": "",
            "wlan_vlan_id": terminal.vlan,
            "wlan_user_mac": terminal.mac.uppercased(),
            "wlan_ac_ip": terminal.wlanACIP,
            "wlan_ac_name": terminal.wlanACName,
            "jsVersion": terminal.jsVersion,
        ]
    }
}
