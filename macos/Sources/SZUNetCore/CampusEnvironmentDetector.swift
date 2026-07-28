import Foundation

public enum CampusNetworkCategory: String, Codable, Equatable, Sendable {
    case dorm
    case teaching
    case ambiguous
    case nonCampus
    case unknown
}

public struct CampusDetection: Equatable, Sendable {
    public var category: CampusNetworkCategory
    public var context: CampusNetworkContext
    public var errorCode: String?

    public init(category: CampusNetworkCategory, context: CampusNetworkContext, errorCode: String? = nil) {
        self.category = category
        self.context = context
        self.errorCode = errorCode
    }
}

public protocol CampusEnvironmentDetecting: Sendable {
    func detect(
        generation: UInt64,
        configuration: CampusProductConfiguration
    ) async -> CampusDetection
}

public protocol TeachingPortalEntryLoading: Sendable {
    func loadEntry(url: URL, sourceIP: String) async throws -> String
}

public final class SourceBoundTeachingPortalLoader: TeachingPortalEntryLoading, @unchecked Sendable {
    private let transport: HTTPTransporting

    public init(transport: HTTPTransporting = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    public func loadEntry(url: URL, sourceIP: String) async throws -> String {
        let response = try await transport.get(
            url,
            query: [:],
            headers: ["Accept": "text/html"],
            timeout: 8,
            sourceIP: sourceIP
        )
        guard response.statusCode == 200, response.finalURL.host == url.host else {
            throw SZUNetError.network("ENV_PORTAL_IDENTITY_UNVERIFIED")
        }
        return response.bodyText
    }
}

public final class CampusEnvironmentDetector: CampusEnvironmentDetecting, @unchecked Sendable {
    private let legacyConfiguration: AppConfiguration
    private let networkProbe: NetworkProbing
    private let routeResolver: SourceRouteResolving
    private let teachingLoader: TeachingPortalEntryLoading

    public init(
        legacyConfiguration: AppConfiguration,
        networkProbe: NetworkProbing = NetworkProbe(),
        routeResolver: SourceRouteResolving = SourceRouteResolver(),
        teachingLoader: TeachingPortalEntryLoading = SourceBoundTeachingPortalLoader()
    ) {
        self.legacyConfiguration = legacyConfiguration
        self.networkProbe = networkProbe
        self.routeResolver = routeResolver
        self.teachingLoader = teachingLoader
    }

    public func detect(
        generation: UInt64,
        configuration: CampusProductConfiguration
    ) async -> CampusDetection {
        let dormStatus: NetworkStatus
        let dormVerified: Bool
        if configuration.dorm.enabled {
            dormStatus = networkProbe.probeGateway(configuration: legacyConfiguration)
            let dormEnvironment = networkProbe.classify(
                configuration: legacyConfiguration,
                status: dormStatus
            )
            dormVerified = dormStatus.gatewayReachable
                && dormEnvironment.autoLoginAvailable
                && !dormStatus.sourceIP.isEmpty
        } else {
            dormStatus = NetworkStatus(gatewayReachable: false, campusInternetOK: false)
            dormVerified = false
        }
        guard configuration.teaching.enabled else {
            return detection(
                generation: generation,
                sourceIP: dormStatus.sourceIP,
                dorm: dormVerified,
                teaching: false,
                category: dormVerified ? .dorm : .unknown,
                errorCode: configuration.dorm.enabled ? nil : "PROVIDER_DISABLED"
            )
        }
        guard let teachingURL = URL(string: configuration.teachingPortalURL),
              teachingURL.scheme == "https", let teachingHost = teachingURL.host else {
            return detection(
                generation: generation,
                sourceIP: dormStatus.sourceIP,
                dorm: dormVerified,
                teaching: false,
                category: dormVerified ? .dorm : .unknown,
                errorCode: "ENV_PORTAL_IDENTITY_UNVERIFIED"
            )
        }
        let teachingRoute = routeResolver.resolve(host: teachingHost, port: 443, timeout: 3)
        var teachingVerified = false
        var teachingHTML = ""
        if teachingRoute.reachable, !teachingRoute.sourceIP.isEmpty {
            if let loaded = try? await teachingLoader.loadEntry(url: teachingURL, sourceIP: teachingRoute.sourceIP),
               (try? SRunPortalDiscovery.discover(
                    entryURL: teachingURL,
                    pageHTML: loaded,
                    sourceIP: teachingRoute.sourceIP
               )) != nil {
                teachingVerified = true
                teachingHTML = loaded
            }
        }
        let category: CampusNetworkCategory
        if dormVerified && teachingVerified { category = .ambiguous }
        else if dormVerified { category = .dorm }
        else if teachingVerified { category = .teaching }
        else if configuration.dorm.enabled,
                !dormStatus.gatewayReachable,
                !teachingRoute.reachable { category = .nonCampus }
        else { category = .unknown }
        let sourceIP = teachingVerified ? teachingRoute.sourceIP : dormStatus.sourceIP
        return CampusDetection(
            category: category,
            context: CampusNetworkContext(
                generation: generation,
                portalURL: teachingVerified ? teachingURL : nil,
                portalHTML: teachingHTML,
                sourceIP: sourceIP,
                sourceRouteBound: !sourceIP.isEmpty,
                dormPortalIdentityVerified: dormVerified,
                teachingPortalIdentityVerified: teachingVerified
            ),
            errorCode: category == .ambiguous ? "ENV_AMBIGUOUS" : nil
        )
    }

    private func detection(
        generation: UInt64,
        sourceIP: String,
        dorm: Bool,
        teaching: Bool,
        category: CampusNetworkCategory,
        errorCode: String?
    ) -> CampusDetection {
        CampusDetection(
            category: category,
            context: CampusNetworkContext(
                generation: generation,
                sourceIP: sourceIP,
                sourceRouteBound: !sourceIP.isEmpty,
                dormPortalIdentityVerified: dorm,
                teachingPortalIdentityVerified: teaching
            ),
            errorCode: errorCode
        )
    }
}
