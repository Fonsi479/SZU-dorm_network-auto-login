import AppKit
import Foundation

public struct SZUNETMacHostCapabilityChecker: SZUNETHostCapabilityChecking {
    public init() {}

    public func supportsOwnershipProtocol(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            guard !bundleIdentifier.isEmpty else { return false }
            let runningURL = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).compactMap(\.bundleURL).first
            let installedURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
            guard let bundleURL = runningURL ?? installedURL,
                  let bundle = Bundle(url: bundleURL) else { return false }
            return (bundle.object(forInfoDictionaryKey: "SZUNETAutomationOwnershipSchema") as? NSNumber)?.intValue ?? 0 >= 1
        }
    }
}
