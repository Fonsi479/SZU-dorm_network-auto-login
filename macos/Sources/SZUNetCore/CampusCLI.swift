import Foundation

public enum CampusCLICommand: String, Codable, CaseIterable, Sendable {
    case status
    case check
    case login
    case logout
    case pause
    case resume
    case enableProbe = "enable-probe"
    case disableProbe = "disable-probe"
    case probeEvery30Seconds = "probe-every-30-seconds"
    case probeEvery60Seconds = "probe-every-60-seconds"
    case probeEvery120Seconds = "probe-every-120-seconds"
    case probeEvery300Seconds = "probe-every-300-seconds"
    case openSettings = "open-settings"
    case diagnostics
}

public enum CampusCLIProvider: String, Codable, CaseIterable, Sendable {
    case auto
    case dorm
    case teaching

    public var providerID: CampusProviderID? {
        switch self {
        case .auto: nil
        case .dorm: .dorm
        case .teaching: .teaching
        }
    }
}

public struct CampusCLIRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var requestId: String
    public var command: CampusCLICommand
    public var provider: CampusCLIProvider
    public var interactive: Bool
    public var timeoutSeconds: Int

    public init(
        schemaVersion: Int = 1,
        requestId: String,
        command: CampusCLICommand,
        provider: CampusCLIProvider = .auto,
        interactive: Bool = false,
        timeoutSeconds: Int = 15
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.command = command
        self.provider = provider
        self.interactive = interactive
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CampusCLIResponse: Encodable, Equatable, Sendable {
    public var schemaVersion: Int
    public var requestId: String
    public var outcome: ProviderAuthOutcome
    public var provider: String
    public var networkContext: String
    public var sessionState: ProviderSessionState
    public var errorCode: String?
    public var retryable: Bool
    public var automaticEnabled: Bool?
    public var ownerAppRunning: Bool?
    public var networkProbeEnabled: Bool?
    public var probeIntervalSeconds: Int?
    public var message: String
    public var timestamp: Date
    public var sanitizedDiagnostics: CampusProductSnapshot?

    public init(
        requestId: String,
        outcome: ProviderAuthOutcome,
        provider: String = "none",
        networkContext: String = "unknown",
        sessionState: ProviderSessionState = .unknown,
        errorCode: String? = nil,
        retryable: Bool = false,
        automaticEnabled: Bool? = nil,
        ownerAppRunning: Bool? = nil,
        networkProbeEnabled: Bool? = nil,
        probeIntervalSeconds: Int? = nil,
        message: String = "",
        timestamp: Date = Date(),
        sanitizedDiagnostics: CampusProductSnapshot? = nil
    ) {
        schemaVersion = 1
        self.requestId = requestId
        self.outcome = outcome
        self.provider = provider
        self.networkContext = networkContext
        self.sessionState = sessionState
        self.errorCode = errorCode
        self.retryable = retryable
        self.automaticEnabled = automaticEnabled
        self.ownerAppRunning = ownerAppRunning
        self.networkProbeEnabled = networkProbeEnabled
        self.probeIntervalSeconds = probeIntervalSeconds
        self.message = String(message.prefix(1_000))
        self.timestamp = timestamp
        self.sanitizedDiagnostics = sanitizedDiagnostics
    }

    public static func blocked(
        requestId: String,
        code: String,
        provider: String = "none"
    ) -> CampusCLIResponse {
        CampusCLIResponse(
            requestId: requestId,
            outcome: .blocked,
            provider: provider,
            sessionState: .blocked,
            errorCode: code,
            message: code
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestId
        case outcome
        case provider
        case networkContext
        case sessionState
        case errorCode
        case retryable
        case automaticEnabled
        case ownerAppRunning
        case networkProbeEnabled
        case probeIntervalSeconds
        case message
        case timestamp
        case sanitizedDiagnostics
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(provider, forKey: .provider)
        try container.encode(networkContext, forKey: .networkContext)
        try container.encode(sessionState, forKey: .sessionState)
        try container.encode(errorCode, forKey: .errorCode)
        try container.encode(retryable, forKey: .retryable)
        try container.encodeIfPresent(automaticEnabled, forKey: .automaticEnabled)
        try container.encodeIfPresent(ownerAppRunning, forKey: .ownerAppRunning)
        try container.encodeIfPresent(networkProbeEnabled, forKey: .networkProbeEnabled)
        try container.encodeIfPresent(probeIntervalSeconds, forKey: .probeIntervalSeconds)
        try container.encode(message, forKey: .message)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(sanitizedDiagnostics, forKey: .sanitizedDiagnostics)
    }
}

public protocol CampusCLIHandling: Sendable {
    func handle(_ request: CampusCLIRequest) async -> CampusCLIResponse
}

public enum CampusCLIProcessor {
    private static let allowedFields: Set<String> = [
        "schemaVersion", "requestId", "command", "provider", "interactive", "timeoutSeconds",
    ]

    public static func process(_ data: Data, handler: CampusCLIHandling) async -> CampusCLIResponse {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return .blocked(requestId: "invalid-request", code: "CFG_INVALID")
        }
        let suppliedRequestID = object["requestId"] as? String
        let requestID = suppliedRequestID ?? "invalid-request"
        guard !containsSecretField(object) else {
            return .blocked(requestId: requestID, code: "CFG_INVALID")
        }
        guard Set(object.keys).isSubset(of: allowedFields),
              let schemaVersion = object["schemaVersion"] as? Int,
              schemaVersion == 1,
              let suppliedRequestID,
              (1...128).contains(suppliedRequestID.count),
              let rawCommand = object["command"] as? String,
              let command = command(rawCommand),
              let provider = CampusCLIProvider(
                rawValue: object["provider"] as? String ?? CampusCLIProvider.auto.rawValue
              ),
              let interactive = optionalBool(object, key: "interactive", defaultValue: false),
              let timeoutSeconds = optionalInt(object, key: "timeoutSeconds", defaultValue: 15),
              (1...120).contains(timeoutSeconds) else {
            return .blocked(requestId: requestID, code: "CFG_INVALID")
        }
        let request = CampusCLIRequest(
            schemaVersion: schemaVersion,
            requestId: requestID,
            command: command,
            provider: provider,
            interactive: interactive,
            timeoutSeconds: timeoutSeconds
        )
        return await withTaskGroup(of: CampusCLIResponse.self) { group in
            group.addTask { await handler.handle(request) }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(request.timeoutSeconds) * 1_000_000_000
                    )
                } catch {
                    return .blocked(
                        requestId: request.requestId,
                        code: "OPERATION_CANCELLED",
                        provider: request.provider.rawValue
                    )
                }
                return CampusCLIResponse(
                    requestId: request.requestId,
                    outcome: .cancelled,
                    provider: request.provider.rawValue,
                    sessionState: .blocked,
                    errorCode: "OPERATION_CANCELLED",
                    message: "OPERATION_CANCELLED"
                )
            }
            let result = await group.next() ?? .blocked(
                requestId: request.requestId,
                code: "INTERNAL_ERROR"
            )
            group.cancelAll()
            return result
        }
    }

    public static func encode(_ response: CampusCLIResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(response)) ?? Data(
            #"{"errorCode":"INTERNAL_ERROR","message":"INTERNAL_ERROR","networkContext":"unknown","outcome":"blocked","provider":"none","requestId":"internal-error","retryable":false,"schemaVersion":1,"sessionState":"blocked","timestamp":"1970-01-01T00:00:00Z"}"#.utf8
        )
        data.append(0x0A)
        return data
    }

    public static func exitCode(for response: CampusCLIResponse) -> Int32 {
        switch response.outcome {
        case .succeeded, .unchanged: 0
        case .blocked: response.errorCode == "INTERNAL_ERROR" ? 70 : 2
        case .failed: response.retryable ? 4 : 3
        case .cancelled: 130
        }
    }

    private static func command(_ rawValue: String) -> CampusCLICommand? {
        if rawValue == "openSettings" { return .openSettings }
        return CampusCLICommand(rawValue: rawValue)
    }

    private static func optionalBool(
        _ object: [String: Any],
        key: String,
        defaultValue: Bool
    ) -> Bool? {
        guard let value = object[key] else { return defaultValue }
        return value as? Bool
    }

    private static func optionalInt(
        _ object: [String: Any],
        key: String,
        defaultValue: Int
    ) -> Int? {
        guard let value = object[key] else { return defaultValue }
        guard !(value is Bool) else { return nil }
        return value as? Int
    }

    private static func containsSecretField(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "")
                if ["password", "secret", "token", "cookie", "authorization", "credentialvalue"]
                    .contains(where: normalized.contains) {
                    return true
                }
                if containsSecretField(child) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsSecretField)
        }
        return false
    }
}
