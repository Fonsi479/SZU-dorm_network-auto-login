import CoreWLAN
import Foundation

public protocol NetworkProbing {
    func probeGateway(configuration: AppConfiguration) -> NetworkStatus
    func probeInternet(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) async -> NetworkStatus
    func classify(configuration: AppConfiguration, status: NetworkStatus) -> NetworkEnvironment
}

public final class NetworkProbe: NetworkProbing {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"

    private let transport: HTTPTransporting
    private let routeResolver: SourceRouteResolving
    private let logger: AppLogger
    private let currentSSIDProvider: () -> String

    public init(
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        routeResolver: SourceRouteResolving = SourceRouteResolver(),
        logger: AppLogger = AppLogger(),
        currentSSIDProvider: @escaping () -> String = NetworkProbe.currentWiFiSSID
    ) {
        self.transport = transport
        self.routeResolver = routeResolver
        self.logger = logger
        self.currentSSIDProvider = currentSSIDProvider
    }

    public func probeGateway(configuration: AppConfiguration) -> NetworkStatus {
        let timeout = TimeInterval(max(1, configuration.network.timeoutSeconds))
        let gateway = resolveGateway(configuration.network.gatewayHosts, timeout: timeout)
        guard gateway.reachable else {
            logger.info("宿舍区网关检测：不可连接 reason=\(gateway.reason)")
            return NetworkStatus(
                gatewayReachable: false,
                campusInternetOK: false,
                sourceIP: gateway.sourceIP,
                gatewayReason: gateway.reason,
                internetReason: "gateway_unreachable"
            )
        }

        logger.info(
            "宿舍区网关检测：可连接 host=\(gateway.host) port=801 "
                + "source_ip=\(gateway.sourceIP.isEmpty ? "-" : gateway.sourceIP)"
        )
        return NetworkStatus(
            gatewayReachable: true,
            campusInternetOK: false,
            gatewayHost: gateway.host,
            sourceIP: gateway.sourceIP,
            gatewayReason: gateway.reason,
            internetReason: "not_probed"
        )
    }

    public func probeInternet(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) async -> NetworkStatus {
        await probeInternet(
            configuration: configuration,
            status: status,
            requiredSourceIP: nil
        )
    }

    /// Probes external reachability while requiring every request to originate
    /// from the verified campus source IP. URLSessionHTTPTransport routes this
    /// through SourceBoundHTTPTransport, whose NWParameters disable proxies and
    /// require that exact local endpoint.
    public func probeCampusEgress(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) async -> NetworkStatus {
        await probeInternet(
            configuration: configuration,
            status: status,
            requiredSourceIP: status.sourceIP
        )
    }

    private func probeInternet(
        configuration: AppConfiguration,
        status: NetworkStatus,
        requiredSourceIP: String?
    ) async -> NetworkStatus {
        guard status.gatewayReachable else { return status }
        let timeout = TimeInterval(max(1, configuration.network.timeoutSeconds))
        let internet = await checkInternet(
            configuration.network,
            timeout: timeout,
            requiredSourceIP: requiredSourceIP
        )
        var result = status
        result.campusInternetOK = internet.ok
        result.internetReason = internet.reason
        result.internetPortalRedirect = internet.portalRedirect
        return result
    }

    public func classify(
        configuration: AppConfiguration,
        status: NetworkStatus
    ) -> NetworkEnvironment {
        let ssid = currentSSIDProvider()
        let onConfiguredWiFi = !ssid.isEmpty && configuration.network.campusWiFiNames.contains(ssid)
        let inCampusNetwork = IPv4CIDR.addressIsInAnyNetwork(
            status.sourceIP,
            networks: configuration.network.campusSourceNetworks
        )

        if status.gatewayReachable && inCampusNetwork {
            return NetworkEnvironment(
                label: "宿舍网络",
                isDormNetwork: true,
                autoLoginAvailable: true,
                wifiSSID: ssid,
                sourceIP: status.sourceIP,
                reason: "gateway_reachable_and_source_ip_verified"
            )
        }
        if status.gatewayReachable {
            return NetworkEnvironment(
                label: "未验证的网关网络",
                isDormNetwork: false,
                autoLoginAvailable: false,
                wifiSSID: ssid,
                sourceIP: status.sourceIP,
                reason: "source_ip_not_in_campus_networks"
            )
        }
        if onConfiguredWiFi {
            return NetworkEnvironment(
                label: "宿舍 Wi-Fi，网关不可达",
                isDormNetwork: true,
                autoLoginAvailable: false,
                wifiSSID: ssid,
                sourceIP: status.sourceIP,
                reason: status.gatewayReason.isEmpty ? "gateway_unreachable" : status.gatewayReason
            )
        }
        return NetworkEnvironment(
            label: "非宿舍网络",
            isDormNetwork: false,
            autoLoginAvailable: false,
            wifiSSID: ssid,
            sourceIP: status.sourceIP,
            reason: status.gatewayReason.isEmpty ? "gateway_unreachable" : status.gatewayReason
        )
    }

    public static func currentWiFiSSID() -> String {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return ssid
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", WiFiDeviceResolver.deviceName()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.lowercased().contains("not associated"),
                  let colon = output.firstIndex(of: ":") else {
                return ""
            }
            return String(output[output.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } catch {
            return ""
        }
    }

    private func resolveGateway(
        _ hosts: [String],
        timeout: TimeInterval
    ) -> (reachable: Bool, host: String, sourceIP: String, reason: String) {
        var failures: [String] = []
        for host in hosts.isEmpty ? ["172.30.255.42"] : hosts {
            let result = routeResolver.resolve(host: host, port: 801, timeout: timeout)
            if result.reachable {
                return (true, host, result.sourceIP, result.reason)
            }
            failures.append("\(host)=\(result.reason)")
        }
        return (false, "", "", failures.isEmpty ? "no_gateway_host" : failures.joined(separator: "; "))
    }

    private func checkInternet(
        _ configuration: NetworkConfiguration,
        timeout: TimeInterval,
        requiredSourceIP: String?
    ) async -> (ok: Bool, reason: String, portalRedirect: Bool) {
        let defaults = NetworkConfiguration.default.testURLs
        var seen = Set<String>()
        let candidates = (configuration.testURLs + defaults)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
            .prefix(max(2, configuration.maxTestURLs))

        var successfulHosts = Set<String>()
        var failures: [String] = []
        var portalRedirect = false

        for rawURL in candidates {
            guard let url = URL(string: rawURL), let host = url.host else {
                failures.append("\(rawURL.prefix(40))=invalid_url")
                continue
            }
            do {
                let response = try await transport.get(
                    url,
                    query: [:],
                    headers: ["User-Agent": Self.userAgent],
                    timeout: timeout,
                    sourceIP: requiredSourceIP
                )
                let preview = String(response.bodyText.prefix(120))
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                let location = response.headers["location"] ?? ""
                if Self.looksLikePortal(location)
                    || Self.looksLikePortal(response.finalURL.absoluteString)
                    || Self.looksLikePortal(preview) {
                    portalRedirect = true
                    failures.append("\(host)=portal_redirect")
                    continue
                }
                if Self.isSuccessfulConnectivityResponse(
                    url: url,
                    statusCode: response.statusCode,
                    preview: preview
                ) {
                    successfulHosts.insert(host)
                    let route = requiredSourceIP == nil ? "default" : "campus-bound"
                    logger.info("网络出口检测：可用 route=\(route) endpoint=external status=\(response.statusCode)")
                    if successfulHosts.count >= 2 {
                        return (true, "ok", false)
                    }
                    failures.append("\(host)=only_one_success")
                } else {
                    failures.append("\(host)=http_\(response.statusCode)")
                }
            } catch {
                failures.append("\(host)=\(Self.shortReason(error))")
            }
        }

        let reason = failures.isEmpty ? "no_test_url" : failures.joined(separator: "; ")
        let route = requiredSourceIP == nil ? "default" : "campus-bound"
        if requiredSourceIP == nil {
            logger.info("网络出口检测：不可用 route=\(route) reason=\(reason)")
        } else {
            logger.info("网络出口检测：不可用 route=\(route) evidence=all_candidates_failed")
        }
        return (false, reason, portalRedirect)
    }

    public static func looksLikePortal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["portal", "drcom", "eportal", "172.30.255.42", "上网认证", "网络认证"]
            .contains { lowered.contains($0) }
    }

    public static func isSuccessfulConnectivityResponse(
        url: URL,
        statusCode: Int,
        preview: String
    ) -> Bool {
        let loweredURL = url.absoluteString.lowercased()
        if loweredURL.contains("baidu.com") {
            return statusCode == 200 && !looksLikePortal(preview)
        }
        if loweredURL.contains("captive.apple.com/hotspot-detect.html") {
            return statusCode == 200 && preview.lowercased().contains("success")
        }
        if [301, 302, 303, 307, 308].contains(statusCode) { return false }
        return (200..<300).contains(statusCode) && !looksLikePortal(preview)
    }

    private static func shortReason(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.contains("timeout") { return "timeout" }
        if description.contains("connection_failed") { return "connection_failed" }
        return String(description.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }
}

private enum WiFiDeviceResolver {
    static func deviceName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "en0" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            for index in lines.indices where lines[index].trimmingCharacters(in: .whitespaces) == "Hardware Port: Wi-Fi" {
                for candidate in lines.dropFirst(index + 1).prefix(3) {
                    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Device:") {
                        return String(trimmed.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {}
        return "en0"
    }
}
