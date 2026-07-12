import Foundation
import ServiceManagement
import SZUNetCore

@available(macOS 13.0, *)
final class LaunchAtLoginController {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered, .notFound:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .unavailable("系统返回了未知状态。")
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw SZUNetError.fileSystem("无法修改登录时启动设置：\(error.localizedDescription)")
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var description: String {
        switch state {
        case .enabled:
            return "已启用"
        case .disabled:
            return "未启用"
        case .requiresApproval:
            return "等待在系统设置中批准"
        case .unavailable(let detail):
            return "不可用：\(detail)"
        }
    }
}

enum LegacyLaunchAgentMigrator {
    static var installedAgents: [URL] {
        DiagnosticReportBuilder.legacyLaunchAgents()
    }

    static func removeAll() throws {
        let domain = "gui/\(getuid())"
        var failures: [String] = []
        for url in installedAgents {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", domain, url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw SZUNetError.fileSystem("部分旧版 LaunchAgent 未能移除：\(failures.joined(separator: "；"))")
        }
    }
}
