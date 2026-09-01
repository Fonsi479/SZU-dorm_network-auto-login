import Foundation
import SZUNETEmbedded
import SZUNetCore

@MainActor
extension AppModel {
    static let embeddedHostID = AppAutomationOwnership.host.hostID
    static let embeddedDisplayName = AppAutomationOwnership.host.displayName
    static let embeddedBundleID = AppAutomationOwnership.host.bundleID

    /// Builds the standalone host configuration from the app's bundle
    /// metadata. Self-built/ad-hoc bundles intentionally fall back to local
    /// Keychain mode; only an explicit, non-empty access group opts into the
    /// official shared group.
    static func makeEmbeddedConfiguration(
        paths: AppPaths,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> SZUNETEmbeddedConfiguration {
        let rawMode = (bundleInfo["SZUNETCredentialMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let accessGroup = (bundleInfo["SZUNETKeychainAccessGroup"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let credentialMode: CampusCredentialAccessMode
        if rawMode == "shared", let accessGroup, !accessGroup.isEmpty {
            credentialMode = .shared(
                accessGroup: accessGroup,
                legacyLocations: [
                    .init(provider: .dorm, service: "szu-netlogin"),
                    .init(
                        provider: .teaching,
                        service: "cn.edu.szu.campus-network.teaching"
                    ),
                    .init(
                        provider: .dorm,
                        service: "com.local.CodexQuotaBar.szu-netlogin"
                    ),
                ]
            )
        } else {
            credentialMode = .local
        }

        return SZUNETEmbeddedConfiguration(
            hostID: embeddedHostID,
            displayName: embeddedDisplayName,
            bundleIdentifier: embeddedBundleID,
            sharedDirectory: paths.applicationSupportDirectory,
            credentialMode: credentialMode,
            managesFallbackScheduling: false
        )
    }
}
