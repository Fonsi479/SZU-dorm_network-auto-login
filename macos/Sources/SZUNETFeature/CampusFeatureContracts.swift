import Foundation

public enum SZUNETCommand: String, Codable, CaseIterable, Sendable {
    case status
    case check
    case login
    case logout
    case pause
    case resume
    case openSettings = "open-settings"
    case diagnostics
}

public enum SZUNETCommandProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case auto
    case dorm
    case teaching
}

public enum SZUNETResultProvider: String, Codable, CaseIterable, Sendable {
    case none
    case auto
    case dorm
    case teaching
}

public enum SZUNETOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case unchanged
    case failed
    case cancelled
    case blocked
}

public enum SZUNETNetworkContext: String, Codable, CaseIterable, Sendable {
    case dorm
    case teaching
    case otherCampus
    case nonCampus
    case ambiguous
    case unknown
}

public enum SZUNETSessionState: String, Codable, CaseIterable, Sendable {
    case online
    case offline
    case unknown
    case blocked
}

public struct SZUNETCommandRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestId: String
    public let command: SZUNETCommand
    public let provider: SZUNETCommandProvider
    public let interactive: Bool
    public let timeoutSeconds: Int

    public init(
        schemaVersion: Int = 1,
        requestId: String,
        command: SZUNETCommand,
        provider: SZUNETCommandProvider = .auto,
        interactive: Bool = false,
        timeoutSeconds: Int = 15
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.command = command
        self.provider = provider
        self.interactive = interactive
        self.timeoutSeconds = min(max(timeoutSeconds, 1), 120)
    }
}

public struct SZUNETCommandResult: Equatable, Sendable {
    public let schemaVersion: Int
    public let requestId: String
    public let outcome: SZUNETOutcome
    public let provider: SZUNETResultProvider
    public let networkContext: SZUNETNetworkContext
    public let sessionState: SZUNETSessionState
    public let errorCode: String?
    public let retryable: Bool

    public init(
        schemaVersion: Int = 1,
        requestId: String,
        outcome: SZUNETOutcome,
        provider: SZUNETResultProvider = .none,
        networkContext: SZUNETNetworkContext = .unknown,
        sessionState: SZUNETSessionState = .unknown,
        errorCode: String? = nil,
        retryable: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.outcome = outcome
        self.provider = provider
        self.networkContext = networkContext
        self.sessionState = sessionState
        self.errorCode = SZUNETStableCode.sanitize(errorCode)
        self.retryable = retryable
    }

    public var isSuccess: Bool {
        outcome == .succeeded || outcome == .unchanged
    }

    public static func blocked(
        requestId: String,
        code: String
    ) -> SZUNETCommandResult {
        SZUNETCommandResult(
            requestId: requestId,
            outcome: .blocked,
            sessionState: .blocked,
            errorCode: code
        )
    }
}

enum SZUNETStableCode {
    private static let allowed: Set<String> = [
        "ADAPTER_CLI_LAUNCH_FAILED",
        "ADAPTER_CLI_UNAVAILABLE",
        "ADAPTER_INTERNAL",
        "ADAPTER_INVALID_RESPONSE",
        "ADAPTER_OUTPUT_TOO_LARGE",
        "ADAPTER_REQUEST_MISMATCH",
        "ADAPTER_SCHEMA_MISMATCH",
        "ADAPTER_TIMEOUT",
        "ADAPTER_UNRECOGNIZED_CODE",
        "AUTH_ACCOUNT_BLOCKED",
        "AUTH_ACCOUNT_NOT_FOUND",
        "AUTH_BAD_PASSWORD",
        "AUTH_DEVICE_LIMIT",
        "AUTH_IP_ALREADY_ONLINE",
        "AUTH_NOT_CONFIRMED",
        "AUTH_PRODUCT_SUFFIX_INVALID",
        "AUTH_SERVER_RATE_LIMIT",
        "CFG_INVALID",
        "CRED_MIGRATION_REQUIRED",
        "CRED_MISSING",
        "CRED_STORE_FAILURE",
        "ENV_AMBIGUOUS",
        "ENV_NETWORK_CHANGED",
        "ENV_NON_CAMPUS",
        "ENV_PORTAL_IDENTITY_UNVERIFIED",
        "ENV_SOURCE_ROUTE_UNVERIFIED",
        "INTERNAL_ERROR",
        "NET_DNS_FAILED",
        "NET_PROXY_INTERCEPTED",
        "NET_TIMEOUT",
        "NET_TLS_FAILED",
        "OPERATION_CANCELLED",
        "OPERATION_IN_PROGRESS",
        "PROVIDER_BACKING_OFF",
        "PROVIDER_DISABLED",
        "SESSION_OFFLINE",
        "SESSION_ONLINE",
        "SESSION_UNKNOWN",
        "SRUN_CHALLENGE_EXPIRED",
        "SRUN_CHALLENGE_FAILED",
        "SRUN_CONFIG_CONFLICT",
        "SRUN_CONFIG_MISSING_ACID",
        "SRUN_CONFIG_MISSING_IP",
        "SRUN_CRYPTO_VECTOR_MISMATCH",
        "SRUN_JSONP_MALFORMED",
        "SRUN_LOGOUT_DISABLED",
    ]

    static func sanitize(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return allowed.contains(value) ? value : "ADAPTER_UNRECOGNIZED_CODE"
    }
}

public struct SZUNETSnapshot: Equatable, Sendable {
    public var adapterEnabled: Bool
    public var status: SZUNETCommandResult?
    public var lastAction: SZUNETCommandResult?
    public var detail: String

    public init(
        adapterEnabled: Bool = false,
        status: SZUNETCommandResult? = nil,
        lastAction: SZUNETCommandResult? = nil,
        detail: String = "适配已关闭；不会启动独立校园网 CLI。"
    ) {
        self.adapterEnabled = adapterEnabled
        self.status = status
        self.lastAction = lastAction
        self.detail = detail
    }
}

public enum SZUNETAdapterError: Error, Equatable, Sendable {
    case executableUnavailable
    case launchFailed
    case outputTooLarge
    case timedOut
    case cancelled
    case invalidResponse
    case unsupportedSchema
    case requestMismatch
}

extension SZUNETAdapterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableUnavailable: "未找到独立 SZUNET CLI。"
        case .launchFailed: "独立 SZUNET CLI 启动失败。"
        case .outputTooLarge: "独立 SZUNET CLI 输出超过限制。"
        case .timedOut: "独立 SZUNET CLI 操作超时。"
        case .cancelled: "独立 SZUNET CLI 操作已取消。"
        case .invalidResponse: "独立 SZUNET CLI 返回无效结果。"
        case .unsupportedSchema: "独立 SZUNET CLI 契约版本不兼容。"
        case .requestMismatch: "独立 SZUNET CLI 请求标识不匹配。"
        }
    }
}
