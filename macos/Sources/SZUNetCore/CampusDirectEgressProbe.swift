import Foundation

public struct CampusDirectEgressResult: Equatable, Sendable {
    public var available: Bool
    public var evidenceCode: String

    public init(available: Bool, evidenceCode: String) {
        self.available = available
        self.evidenceCode = evidenceCode
    }
}

public protocol CampusDirectEgressProbing: Sendable {
    func check(context: CampusNetworkContext) async -> CampusDirectEgressResult
}

public final class CampusDirectEgressProbe: CampusDirectEgressProbing, @unchecked Sendable {
    private let configuration: AppConfiguration
    private let networkProbe: NetworkProbe

    public init(
        configuration: AppConfiguration,
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        logger: AppLogger = AppLogger()
    ) {
        self.configuration = configuration
        networkProbe = NetworkProbe(transport: transport, logger: logger)
    }

    public func check(context: CampusNetworkContext) async -> CampusDirectEgressResult {
        guard context.sourceRouteBound,
              context.dormPortalIdentityVerified,
              !context.sourceIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CampusDirectEgressResult(
                available: false,
                evidenceCode: "ENV_SOURCE_ROUTE_UNVERIFIED"
            )
        }
        let status = await networkProbe.probeCampusEgress(
            configuration: configuration,
            status: NetworkStatus(
                gatewayReachable: true,
                campusInternetOK: false,
                sourceIP: context.sourceIP,
                gatewayReason: "verified_by_environment_detector",
                internetReason: "not_probed"
            )
        )
        return CampusDirectEgressResult(
            available: status.campusInternetOK,
            evidenceCode: status.campusInternetOK
                ? "CAMPUS_EGRESS_AVAILABLE"
                : "CAMPUS_EGRESS_UNAVAILABLE"
        )
    }
}

struct UnavailableCampusDirectEgressProbe: CampusDirectEgressProbing {
    func check(context: CampusNetworkContext) async -> CampusDirectEgressResult {
        CampusDirectEgressResult(
            available: false,
            evidenceCode: "CAMPUS_EGRESS_PROBE_UNAVAILABLE"
        )
    }
}
