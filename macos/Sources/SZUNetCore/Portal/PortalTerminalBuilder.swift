import Foundation

enum PortalTerminalBuilder {
    static func build(
        pageURL: String,
        pageText: String,
        onlineRecord: [String: Any],
        sourceIP: String,
        jsVersion: String
    ) -> PortalTerminalParameters {
        let query = URLComponents(string: pageURL)?.queryItems?.reduce(into: [String: String]()) {
            if $0[$1.name] == nil { $0[$1.name] = $1.value ?? "" }
        } ?? [:]
        let variables = PortalCodec.pageVariables(pageText)
        func first(_ names: [String]) -> String {
            for name in names {
                let value = query[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { return value }
            }
            return ""
        }
        func firstIP(_ values: [String]) -> String {
            for value in values {
                let normalized = IPv4CIDR.normalized(value)
                if !normalized.isEmpty { return normalized }
            }
            return ""
        }

        let pageIP = firstIP([
            first(["ip", "wlanuserip", "userip", "user-ip", "client_ip", "UserIP", "uip", "station_ip"]),
            variables["v46ip"] ?? "",
            variables["ss5"] ?? "",
            variables["v4ip"] ?? "",
            PortalCodec.hexIPToDotted(variables["ss3"] ?? ""),
        ])
        let onlineIP = IPv4CIDR.normalized(PortalCodec.string(onlineRecord, keys: ["online_ip"]))
        // Match the browser's `term.init`: page/query identity is authoritative
        // for the portal request. Online-list identity is only a fallback.
        let terminalIP = pageIP.isEmpty
            ? (onlineIP.isEmpty ? IPv4CIDR.normalized(sourceIP) : onlineIP)
            : pageIP

        let pageMAC = PortalCodec.normalizedMAC(
            first(["mac", "usermac", "wlanusermac", "umac", "client_mac", "station_mac"])
        )
        let variableMAC = PortalCodec.normalizedMAC(
            variables["ss4"] ?? variables["olmac"] ?? ""
        )
        let onlineMAC = PortalCodec.normalizedMAC(
            PortalCodec.string(onlineRecord, keys: ["online_mac"])
        )
        // Preserve the portal page's all-zero sentinel. The live SZU portal
        // rejects logout when the client replaces it with online_list or the
        // private Wi-Fi MAC. Server MAC remains available separately for unbind.
        let terminalMAC = pageMAC
            .or(variableMAC)
            .or(PortalCodec.nonSentinelMAC(onlineMAC))
            .or(onlineMAC)
            .or("000000000000")

        let vlan = first(["vlan", "vlanid"])
            .or(variables["vlanid"] ?? "")
            .or("0")
        // Browser code only reads AC identity from redirect query parameters.
        // Do not manufacture it from online_list.nas_ip.
        let acIP = first(["wlanacip", "acip", "switchip", "nasip", "nas-ip"])
        let acName = first(["wlanacname", "sysname", "nasname", "nas-name"])
        return PortalTerminalParameters(
            ip: terminalIP,
            mac: terminalMAC,
            vlan: vlan,
            wlanACIP: acIP,
            wlanACName: acName,
            jsVersion: jsVersion.isEmpty ? "4.1.3" : jsVersion,
            pageURL: pageURL
        )
    }

}

private extension String {
    func or(_ fallback: @autoclosure () -> String) -> String {
        isEmpty ? fallback() : self
    }
}
