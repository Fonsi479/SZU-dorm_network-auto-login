import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    var isAutomationOwner: Bool {
        automationOwnershipSnapshot.isCurrentHostOwner
    }

    var automationOwnershipDescription: String {
        if let currentOwner = automationOwnershipSnapshot.currentOwner {
            if currentOwner.supportsOwnershipProtocol {
                return "\(currentOwner.displayName) 正在管理自动化；如需切换，请在设置中显式转移所有权。"
            }
            return "检测到旧版 \(currentOwner.displayName)，请先升级或关闭其自动化后再转移。"
        }
        if let error = automationOwnership.lastError {
            return "无法读取校园网自动化所有权：\(error.localizedDescription)"
        }
        return "当前没有自动化所有者。"
    }

    @discardableResult
    func refreshAutomationOwnership() -> CampusAutomationOwnershipSnapshot {
        automationOwnershipSnapshot = automationOwnership.refresh()
        return automationOwnershipSnapshot
    }

    /// Returns a user-facing action result without touching configuration or
    /// credentials when another host owns the automation lease.
    func automationOwnershipBlockedResult(action: String) -> LoginActionResult {
        LoginActionResult(
            outcome: .failed,
            title: "无法\(action)",
            detail: automationOwnershipDescription,
            reason: "automation_owner_conflict"
        )
    }

    /// Automatic lanes call this immediately before scheduling and again from
    /// inside the operation closure, immediately before the Core reads a
    /// credential.
    func verifyAutomationOwner() -> Bool {
        let verified = automationOwnership.verifyOwner()
        automationOwnershipSnapshot = automationOwnership.snapshot
        return verified
    }

    func requireAutomationOwnership(for action: String) -> Bool {
        guard verifyAutomationOwner() else {
            onResult?(automationOwnershipBlockedResult(action: action), false)
            return false
        }
        return true
    }
}
