import Foundation
import Testing
@testable import SZUNetCore

@Suite("Campus product configuration and CLI", .serialized)
struct CampusProductTests {
    @Test("schema v2 defaults keep Dorm on, Teaching off, and contain no secret fields")
    func defaultsAndSafeEncoding() throws {
        let configuration = CampusProductConfiguration.default
        let data = try JSONEncoder().encode(configuration)
        let text = String(decoding: data, as: UTF8.self).lowercased()

        #expect(configuration.schemaVersion == 2)
        #expect(configuration.dorm.enabled)
        #expect(!configuration.teaching.enabled)
        #expect(!text.contains("password"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("token"))
        #expect(!text.contains("cookie"))
    }

    @Test("schema v1 migration preserves Dorm account reference and never enables Teaching")
    func schemaV1Migration() {
        var legacy = AppConfiguration.default
        legacy.user.username = "student-label"
        legacy.security.keychainAccount = "legacy-reference"
        let migrated = CampusProductConfiguration.migrating(legacy)

        #expect(migrated.dorm.enabled)
        #expect(migrated.dorm.accountLabel == "student-label")
        #expect(migrated.dorm.credentialReference == "legacy-reference")
        #expect(!migrated.teaching.enabled)
    }

    @Test("provider settings reject unsafe credential references and portal hosts")
    func providerSettingsValidation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CampusProviderSettingsStore(fileURL: root.appendingPathComponent("providers.json"))
        var configuration = CampusProductConfiguration.default
        configuration.teaching.credentialReference = "bad reference with spaces"
        #expect(throws: SZUNetError.self) { try store.save(configuration) }

        configuration.teaching.credentialReference = "teaching-default"
        configuration.teachingPortalURL = "https://example.invalid/srun_portal_pc"
        #expect(throws: SZUNetError.self) { try store.save(configuration) }
    }

    @Test("credential broker opens only an enabled selected provider reference")
    func brokerProviderBoundary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = CampusProviderSettingsStore(fileURL: root.appendingPathComponent("providers.json"))
        var settings = CampusProductConfiguration.default
        settings.dorm.credentialReference = "dorm-ref"
        settings.teaching.credentialReference = "teaching-ref"
        try settingsStore.save(settings)
        let store = CampusCredentialStoreSpy(values: ["dorm-ref": "synthetic-value", "teaching-ref": "unused"])
        let broker = CampusKeychainCredentialBroker(settingsStore: settingsStore, credentialStore: store)

        #expect(try await broker.openCredential(for: .dorm, username: "label") != nil)
        #expect(try await broker.openCredential(for: .teaching, username: "label") == nil)
        #expect(store.readAccounts == ["dorm-ref"])
    }

    @Test("detector uses injected evidence and fails closed on ambiguity")
    func detectorCategories() async throws {
        let portal = try #require(URL(string: "https://net.szu.edu.cn/srun_portal_pc"))
        let html = "<script>var CONFIG={acid:'17',ip:'203.0.113.41'};</script>"
        let settings = CampusProductConfiguration(teachingPortalURL: portal.absoluteString)
        let dormProbe = ProductNetworkProbe(dormVerified: true)
        let detector = CampusEnvironmentDetector(
            legacyConfiguration: .default,
            networkProbe: dormProbe,
            routeResolver: ProductRouteResolver(route: SourceRoute(reachable: true, sourceIP: "203.0.113.41")),
            teachingLoader: ProductTeachingLoader(html: html)
        )

        var enabledSettings = settings
        enabledSettings.teaching.enabled = true
        let result = await detector.detect(generation: 7, configuration: enabledSettings)
        #expect(result.category == .ambiguous)
        #expect(result.errorCode == "ENV_AMBIGUOUS")
        #expect(result.context.generation == 7)
    }

    @Test("disabled Providers perform zero environment probes")
    func disabledProvidersDoNotProbe() async {
        let network = ProductNetworkProbe(dormVerified: true)
        let route = ProductRouteResolver(
            route: SourceRoute(reachable: true, sourceIP: "203.0.113.41")
        )
        let detector = CampusEnvironmentDetector(
            legacyConfiguration: .default,
            networkProbe: network,
            routeResolver: route,
            teachingLoader: ProductTeachingLoader(
                html: "<script>var CONFIG={acid:'17',ip:'203.0.113.41'};</script>"
            )
        )
        var settings = CampusProductConfiguration.default
        settings.dorm.enabled = false
        settings.teaching.enabled = false

        let result = await detector.detect(generation: 0, configuration: settings)

        #expect(result.category == .unknown)
        #expect(network.probeCalls == 0)
        #expect(route.resolveCalls == 0)
    }

    @Test("each enabled Provider probes only its own environment")
    func providerSpecificDetection() async {
        let network = ProductNetworkProbe(dormVerified: true)
        let route = ProductRouteResolver(
            route: SourceRoute(reachable: true, sourceIP: "203.0.113.41")
        )
        let detector = CampusEnvironmentDetector(
            legacyConfiguration: .default,
            networkProbe: network,
            routeResolver: route,
            teachingLoader: ProductTeachingLoader(
                html: "<script>var CONFIG={acid:'17',ip:'203.0.113.41'};</script>"
            )
        )
        var dormOnly = CampusProductConfiguration.default
        _ = await detector.detect(generation: 0, configuration: dormOnly)
        #expect(network.probeCalls == 1)
        #expect(route.resolveCalls == 0)

        dormOnly.dorm.enabled = false
        dormOnly.teaching.enabled = true
        _ = await detector.detect(generation: 1, configuration: dormOnly)
        #expect(network.probeCalls == 1)
        #expect(route.resolveCalls == 1)
    }

    @Test("JSON CLI rejects secret fields and emits one response object")
    func cliSecretRejectionAndSingleObject() async throws {
        let handler = CampusCLIHandlerSpy()
        let forbidden = Data(#"{"schemaVersion":1,"requestId":"r1","command":"status","password":"no"}"#.utf8)
        let rejected = await CampusCLIProcessor.process(forbidden, handler: handler)
        #expect(rejected.errorCode == "CFG_INVALID")
        #expect(await handler.calls == 0)

        let request = try JSONEncoder().encode(CampusCLIRequest(requestId: "r2", command: .status))
        let accepted = await CampusCLIProcessor.process(request, handler: handler)
        let encoded = CampusCLIProcessor.encode(accepted)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let required = Set([
            "schemaVersion", "requestId", "outcome", "provider", "networkContext",
            "sessionState", "errorCode", "retryable", "message", "timestamp",
        ])
        #expect(required.isSubset(of: Set(object.keys)))
        #expect(object["errorCode"] is NSNull)
        #expect(await handler.calls == 1)
        #expect(String(decoding: encoded, as: UTF8.self).split(separator: "\n").count == 1)
    }

    @Test("product snapshots mask full account labels before CLI or Feature export")
    func productSnapshotMasksAccounts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = CampusProductConfiguration(
            dorm: .init(
                enabled: true,
                accountLabel: "synthetic-user@hlw",
                credentialReference: "dorm-ref"
            )
        )
        let store = CampusProviderSettingsStore(fileURL: root.appendingPathComponent("providers.json"))
        try store.save(configuration)
        let coordinator = CampusNetworkCoordinator(
            providers: [],
            credentialBroker: CampusCredentialBrokerStub(),
            settings: configuration.coordinatorSettings,
            authenticationLockURL: root.appendingPathComponent("auth.lock")
        )
        let controller = CampusProductController(
            detector: CampusDetectorStub(),
            coordinator: coordinator,
            settingsStore: store,
            pauseStore: PauseStore(
                fileURL: root.appendingPathComponent("pause.json"),
                lockFileURL: root.appendingPathComponent("pause.lock"),
                legacyFileURL: root.appendingPathComponent("legacy-pause"),
                migrationFileURL: root.appendingPathComponent("pause-migrated")
            ),
            configuration: configuration
        )

        let snapshot = await controller.currentSnapshot()
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(snapshot.dorm.accountLabel == "s***r@hlw")
        #expect(!encoded.contains("synthetic-user"))
    }

    @Test("product refresh reports the selected Provider session without reading credentials")
    func productRefreshIsCredentialFree() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = CampusProductConfiguration(
            dorm: .init(
                enabled: true,
                accountLabel: "synthetic-user",
                credentialReference: "dorm-ref"
            )
        )
        let store = CampusProviderSettingsStore(fileURL: root.appendingPathComponent("providers.json"))
        try store.save(configuration)
        let broker = CountingCredentialBroker()
        let coordinator = CampusNetworkCoordinator(
            providers: [ProductProviderStub()],
            credentialBroker: broker,
            settings: configuration.coordinatorSettings,
            authenticationLockURL: root.appendingPathComponent("auth.lock")
        )
        let controller = CampusProductController(
            detector: DormDetectorStub(),
            coordinator: coordinator,
            settingsStore: store,
            pauseStore: PauseStore(
                fileURL: root.appendingPathComponent("pause.json"),
                lockFileURL: root.appendingPathComponent("pause.lock"),
                legacyFileURL: root.appendingPathComponent("legacy-pause"),
                migrationFileURL: root.appendingPathComponent("pause-migrated")
            ),
            configuration: configuration
        )

        let snapshot = await controller.refresh()

        #expect(snapshot.category == .dorm)
        #expect(snapshot.dorm.lifecycle == "offline")
        #expect(await broker.readCount == 0)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("campus-product-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class CampusCredentialStoreSpy: CredentialStoring {
    let values: [String: String]
    private(set) var readAccounts: [String] = []
    init(values: [String: String]) { self.values = values }
    func password(service: String, account: String) throws -> String? {
        readAccounts.append(account)
        return values[account]
    }
    func setPassword(_ password: String, service: String, account: String) throws {}
    func deletePassword(service: String, account: String) throws {}
}

private final class ProductNetworkProbe: NetworkProbing {
    let dormVerified: Bool
    private(set) var probeCalls = 0
    init(dormVerified: Bool) { self.dormVerified = dormVerified }
    func probeGateway(configuration: AppConfiguration) -> NetworkStatus {
        probeCalls += 1
        return NetworkStatus(
            gatewayReachable: dormVerified,
            campusInternetOK: false,
            gatewayHost: dormVerified ? "172.30.255.42" : "",
            sourceIP: dormVerified ? "203.0.113.41" : "",
            gatewayReason: dormVerified ? "connected" : "unreachable"
        )
    }
    func probeInternet(configuration: AppConfiguration, status: NetworkStatus) async -> NetworkStatus { status }
    func classify(configuration: AppConfiguration, status: NetworkStatus) -> NetworkEnvironment {
        NetworkEnvironment(
            label: dormVerified ? "Dorm" : "Unknown",
            isDormNetwork: dormVerified,
            autoLoginAvailable: dormVerified,
            sourceIP: status.sourceIP
        )
    }
}

private final class ProductRouteResolver: SourceRouteResolving {
    let route: SourceRoute
    private(set) var resolveCalls = 0
    init(route: SourceRoute) { self.route = route }
    func resolve(host: String, port: UInt16, timeout: TimeInterval) -> SourceRoute {
        resolveCalls += 1
        return route
    }
}

private struct ProductTeachingLoader: TeachingPortalEntryLoading {
    let html: String
    func loadEntry(url: URL, sourceIP: String) async throws -> String { html }
}

private actor CampusCLIHandlerSpy: CampusCLIHandling {
    private(set) var calls = 0
    func handle(_ request: CampusCLIRequest) async -> CampusCLIResponse {
        calls += 1
        return CampusCLIResponse(
            requestId: request.requestId,
            outcome: .unchanged,
            provider: request.provider.rawValue,
            message: "unchanged"
        )
    }
}

private actor CampusCredentialBrokerStub: CampusCredentialBroker {
    func openCredential(for providerID: CampusProviderID, username: String) async throws -> CredentialHandle? {
        nil
    }
}

private struct CampusDetectorStub: CampusEnvironmentDetecting {
    func detect(
        generation: UInt64,
        configuration: CampusProductConfiguration
    ) async -> CampusDetection {
        CampusDetection(category: .unknown, context: CampusNetworkContext(generation: generation))
    }
}

private struct DormDetectorStub: CampusEnvironmentDetecting {
    func detect(
        generation: UInt64,
        configuration: CampusProductConfiguration
    ) async -> CampusDetection {
        CampusDetection(
            category: .dorm,
            context: CampusNetworkContext(
                generation: generation,
                sourceIP: "198.51.100.27",
                sourceRouteBound: true,
                dormPortalIdentityVerified: true
            )
        )
    }
}

private actor CountingCredentialBroker: CampusCredentialBroker {
    private(set) var readCount = 0
    func openCredential(for providerID: CampusProviderID, username: String) async throws -> CredentialHandle? {
        readCount += 1
        return CredentialHandle("synthetic-only")
    }
}

private actor ProductProviderStub: NetworkAuthProvider {
    nonisolated let providerID = CampusProviderID.dorm

    func probeEnvironment(_ context: CampusNetworkContext) async -> ProviderProbe {
        ProviderProbe(
            providerID: .dorm,
            support: context.dormPortalIdentityVerified ? .supported : .unsupported,
            confidence: context.dormPortalIdentityVerified ? .verified : .unknown,
            sourceIP: context.sourceIP,
            clientIP: context.sourceIP
        )
    }

    func sessionStatus(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderSessionResult {
        ProviderSessionResult(state: .offline, clientIP: probe.clientIP)
    }

    func login(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String,
        credential: CredentialHandle
    ) async -> ProviderAuthResult {
        ProviderAuthResult(outcome: .succeeded, providerID: .dorm, sessionState: .online)
    }

    func logout(
        _ context: CampusNetworkContext,
        probe: ProviderProbe,
        username: String
    ) async -> ProviderAuthResult {
        ProviderAuthResult(outcome: .succeeded, providerID: .dorm, sessionState: .offline)
    }

    func cancelPendingOperations(generation: UInt64) async {}
}
