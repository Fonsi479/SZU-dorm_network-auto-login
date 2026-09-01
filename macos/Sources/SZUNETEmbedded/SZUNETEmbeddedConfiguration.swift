import Foundation
import SZUNetCore

public struct SZUNETEmbeddedConfiguration: Equatable, Sendable {
    public var hostID: String
    public var displayName: String
    public var bundleIdentifier: String
    public var sharedDirectory: URL
    public var credentialMode: CampusCredentialAccessMode
    /// When true the runtime owns its own periodic fallback task. Host shells
    /// with an existing scheduler (the standalone menu-bar app) set this to
    /// false and drive refresh/login explicitly through the runtime methods.
    public var managesFallbackScheduling: Bool

    public init(
        hostID: String,
        displayName: String,
        bundleIdentifier: String,
        sharedDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/szu-netlogin", isDirectory: true),
        credentialMode: CampusCredentialAccessMode = .local,
        managesFallbackScheduling: Bool = true
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.sharedDirectory = sharedDirectory
        self.credentialMode = credentialMode
        self.managesFallbackScheduling = managesFallbackScheduling
    }
}

public extension CampusCredentialAccessMode {
    var sharesCredentialsWithOfficialClients: Bool {
        if case .shared = self { return true }
        return false
    }
}
