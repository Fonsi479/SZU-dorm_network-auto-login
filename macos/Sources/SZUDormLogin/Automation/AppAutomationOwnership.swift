import Foundation
import SZUNetCore

/// Coordinates the standalone application's participation in the shared
/// campus-network automation state.
///
/// The standalone app is deliberately a normal ownership-protocol peer.  It
/// may claim an empty store on launch, but it never takes ownership away from
/// another peer implicitly.  When another supported host owns the store the
/// app can still perform explicit, user-triggered operations; only periodic
/// probes and automatic authentication are gated by ``verifyOwner()``.
@MainActor
final class AppAutomationOwnership {
    nonisolated static let host = CampusAutomationHost(
        hostID: "com.szu-netlogin.dorm-login",
        displayName: "SZU Dorm Login",
        bundleID: "com.szu-netlogin.dorm-login",
        supportsOwnershipProtocol: true
    )

    private let store: CampusAutomationStore
    let descriptor: CampusAutomationHost
    private(set) var snapshot: CampusAutomationOwnershipSnapshot
    private(set) var lastError: Error?

    static func legacyOwnerIfNeeded(
        paths: AppPaths,
        fileManager: FileManager = .default
    ) -> CampusAutomationHost? {
        guard !fileManager.fileExists(atPath: paths.automationFile.path) else { return nil }
        let hasExistingConfiguration = fileManager.fileExists(
            atPath: paths.campusProviderConfigurationFile.path
        ) || fileManager.fileExists(atPath: paths.configurationFile.path)
        guard hasExistingConfiguration else { return nil }
        return CampusAutomationHost(
            hostID: host.hostID,
            displayName: host.displayName,
            bundleID: host.bundleID,
            supportsOwnershipProtocol: false
        )
    }

    init(
        store: CampusAutomationStore = CampusAutomationStore(),
        descriptor: CampusAutomationHost = AppAutomationOwnership.host
    ) {
        self.store = store
        self.descriptor = descriptor
        snapshot = CampusAutomationOwnershipSnapshot(
            currentOwner: nil,
            ownerRunning: false,
            canTransfer: true,
            isCurrentHostOwner: false
        )
    }

    /// Starts the standalone app's automation session when ownership is
    /// available.  Existing ownership by another host is never replaced.
    @discardableResult
    func start() -> Bool {
        do {
            let current = try store.ownershipSnapshot(for: descriptor.hostID)
            if current.isCurrentHostOwner {
                snapshot = try store.setOwnerRunning(true, hostID: descriptor.hostID)
                lastError = nil
                return true
            }
            guard current.currentOwner == nil else {
                snapshot = current
                lastError = nil
                return false
            }
            snapshot = try store.claimOwnership(for: descriptor, running: true)
            lastError = nil
            return true
        } catch {
            lastError = error
            refreshSnapshotAfterFailure()
            return false
        }
    }

    /// Marks this host as no longer running while retaining ownership.  The
    /// retained owner record prevents a second client from taking over
    /// silently after this app exits.
    func stop() {
        guard verifyOwner() else { return }
        do {
            snapshot = try store.setOwnerRunning(false, hostID: descriptor.hostID)
            lastError = nil
        } catch {
            lastError = error
            refreshSnapshotAfterFailure()
        }
    }

    /// Re-reads the shared ownership record for presentation and gating.
    @discardableResult
    func refresh() -> CampusAutomationOwnershipSnapshot {
        do {
            snapshot = try store.ownershipSnapshot(for: descriptor.hostID)
            lastError = nil
        } catch {
            lastError = error
        }
        return snapshot
    }

    /// Re-checks the owner immediately before an automatic operation.  This
    /// must remain a fresh store read; cached snapshots are presentation-only.
    func verifyOwner() -> Bool {
        do {
            let verified = try store.verifyOwnership(hostID: descriptor.hostID)
            snapshot = try store.ownershipSnapshot(for: descriptor.hostID)
            lastError = nil
            return verified
        } catch {
            lastError = error
            refreshSnapshotAfterFailure()
            return false
        }
    }

    /// Explicit transfer used by a future shared management view.  No caller
    /// path invokes this implicitly during startup.
    @discardableResult
    func transferOwnership() throws -> CampusAutomationOwnershipSnapshot {
        snapshot = try store.transferOwnership(to: descriptor, running: true)
        lastError = nil
        return snapshot
    }

    /// Explicit release used when the user chooses to hand ownership back.
    @discardableResult
    func releaseOwnership() throws -> CampusAutomationOwnershipSnapshot {
        snapshot = try store.releaseOwnership(hostID: descriptor.hostID)
        lastError = nil
        return snapshot
    }

    func sharedProbePreferences() -> (enabled: Bool, intervalSeconds: Int) {
        guard let configuration = try? store.load() else {
            return (
                CampusAutomationPreferences.defaultProbeIntervalSeconds > 0,
                CampusAutomationPreferences.defaultProbeIntervalSeconds
            )
        }
        return (configuration.networkProbeEnabled, configuration.probeIntervalSeconds)
    }

    @discardableResult
    func setSharedProbePreferences(
        enabled: Bool,
        intervalSeconds: Int
    ) throws -> (enabled: Bool, intervalSeconds: Int) {
        let configuration = try store.updateProbe(
            enabled: enabled,
            intervalSeconds: intervalSeconds
        )
        lastError = nil
        return (configuration.networkProbeEnabled, configuration.probeIntervalSeconds)
    }

    private func refreshSnapshotAfterFailure() {
        guard let refreshed = try? store.ownershipSnapshot(for: descriptor.hostID) else { return }
        snapshot = refreshed
    }
}
