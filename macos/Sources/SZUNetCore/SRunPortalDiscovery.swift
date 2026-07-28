import Foundation

public struct SRunPortalDiscoveryError: LocalizedError, Equatable {
    public let code: String
    public var errorDescription: String? { code }

    init(_ code: String) {
        self.code = code
    }
}

public struct SRunPortalConfiguration: Equatable, Sendable {
    public let portalURL: URL
    public let acid: String
    public let clientIP: String
}

public enum SRunPortalDiscovery {
    public static func discover(
        entryURL: URL,
        pageHTML: String,
        sourceIP: String,
        allowedHosts: Set<String> = ["net.szu.edu.cn"]
    ) throws -> SRunPortalConfiguration {
        guard entryURL.scheme?.lowercased() == "https",
              let host = entryURL.host?.lowercased(),
              allowedHosts.contains(host) else {
            throw SRunPortalDiscoveryError("ENV_PORTAL_IDENTITY_UNVERIFIED")
        }
        var acidValues = Set<String>()
        var ipValues = Set<String>()
        if let components = URLComponents(url: entryURL, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                let name = item.name.lowercased()
                let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name == "acid" || name == "ac_id" { acidValues.insert(value) }
                if name == "ip" || name == "user_ip" || name == "client_ip" { ipValues.insert(value) }
            }
        }
        acidValues.formUnion(captures(
            #"(?i)(?:["']?acid["']?|["']?ac_id["']?)\s*[:=]\s*["']?([0-9]+)"#,
            in: pageHTML
        ))
        ipValues.formUnion(captures(
            #"(?i)(?:["']?ip["']?|["']?client_ip["']?|["']?user_ip["']?)\s*[:=]\s*["']?([0-9]{1,3}(?:\.[0-9]{1,3}){3})"#,
            in: pageHTML
        ))
        let normalizedSource = IPv4CIDR.normalized(sourceIP)
        if !normalizedSource.isEmpty { ipValues.insert(normalizedSource) }
        acidValues = Set(acidValues.filter { Int($0).map { $0 > 0 } == true })
        ipValues = Set(ipValues.map(IPv4CIDR.normalized).filter(isIPv4))
        guard !acidValues.isEmpty else { throw SRunPortalDiscoveryError("SRUN_CONFIG_MISSING_ACID") }
        guard !ipValues.isEmpty else { throw SRunPortalDiscoveryError("SRUN_CONFIG_MISSING_IP") }
        guard acidValues.count == 1, ipValues.count == 1 else {
            throw SRunPortalDiscoveryError("SRUN_CONFIG_CONFLICT")
        }
        return SRunPortalConfiguration(
            portalURL: entryURL,
            acid: acidValues.first!,
            clientIP: ipValues.first!
        )
    }

    private static func captures(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[capture])
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0 ... 255).contains($0) } == true }
    }
}
