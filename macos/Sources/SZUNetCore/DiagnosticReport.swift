import Foundation

public final class DiagnosticReportBuilder {
    private let paths: AppPaths
    private let coordinator: LoginCoordinator
    private let logger: AppLogger
    private let launchAtLoginStatus: () -> String

    public init(
        paths: AppPaths = .standard,
        coordinator: LoginCoordinator,
        logger: AppLogger = AppLogger(),
        launchAtLoginStatus: @escaping () -> String = { "由主应用查询" }
    ) {
        self.paths = paths
        self.coordinator = coordinator
        self.logger = logger
        self.launchAtLoginStatus = launchAtLoginStatus
    }

    public func create() async throws -> URL {
        try FileManager.default.createDirectory(
            at: paths.diagnosticDirectory,
            withIntermediateDirectories: true
        )
        let report = await build()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = paths.diagnosticDirectory
            .appendingPathComponent("diagnostic-report-\(formatter.string(from: Date())).txt")
        do {
            try Data(report.utf8).write(to: output, options: .atomic)
            return output
        } catch {
            throw SZUNetError.fileSystem("无法写入诊断报告：\(error.localizedDescription)")
        }
    }

    public func build() async -> String {
        var lines = [
            "SZU Dorm Login 原生 Swift 诊断报告",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "应用版本：\(Self.versionDescription)",
            "运行架构：\(Self.architecture)",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "实现：Swift 原生（不依赖 Python）",
            "",
            "== 配置与凭据 ==",
            "配置文件：\(paths.configurationFile.path)",
        ]

        var configuration: AppConfiguration?
        do {
            let loaded = try coordinator.configurationStore.load()
            configuration = loaded.configuration
            lines.append("配置读取：通过")
            lines.append("账号：\(Self.mask(loaded.configuration.user.username))")
            lines.append("钥匙串服务：\(loaded.configuration.security.keychainService)")
            let hasPassword = try coordinator.currentPassword(configuration: loaded.configuration)?.isEmpty == false
            lines.append("钥匙串密码：\(hasPassword ? "已保存" : "未保存")")
        } catch {
            lines.append("配置读取：失败，\(error.localizedDescription)")
        }

        lines += [
            "",
            "== 自动运行状态 ==",
            "自动登录：\(coordinator.pauseStore.description())",
            "登录时启动：\(launchAtLoginStatus())",
        ]

        if configuration != nil {
            do {
                let (_, status, environment) = try await coordinator.probe()
                lines += [
                    "",
                    "== 网络探测 ==",
                    "网络环境：\(environment.label)",
                    "自动登录可用：\(environment.autoLoginAvailable ? "是" : "否")",
                    "当前 Wi-Fi：\(environment.wifiSSID.isEmpty ? "-" : environment.wifiSSID)",
                    "宿舍区网关可达：\(status.gatewayReachable ? "是" : "否")",
                    "网关：\(status.gatewayHost.isEmpty ? "-" : status.gatewayHost)",
                    "源 IP：\(status.sourceIP.isEmpty ? "-" : status.sourceIP)",
                    "门户会话：\(status.campusSessionState.rawValue)",
                    "校园网出口可用：\(status.campusInternetOK ? "是" : "否")",
                    "门户重定向：\(status.internetPortalRedirect ? "是" : "否")",
                    "网关检测原因：\(status.gatewayReason.isEmpty ? "-" : status.gatewayReason)",
                    "出口检测原因：\(status.internetReason.isEmpty ? "-" : status.internetReason)",
                ]
            } catch {
                lines += ["", "== 网络探测 ==", "网络探测失败：\(error.localizedDescription)"]
            }
        }

        let legacyAgents = Self.legacyLaunchAgents()
        lines += [
            "",
            "== 旧版迁移检查 ==",
            "旧 Python LaunchAgent 数量：\(legacyAgents.count)",
        ]
        lines += legacyAgents.map { "- \($0.path)" }

        lines += [
            "",
            "== 最近脱敏日志 ==",
            logger.tail(maxLines: 80).isEmpty ? "日志为空" : logger.tail(maxLines: 80),
            "",
        ]
        return AppLogger.redact(lines.joined(separator: "\n"))
    }

    public static func legacyLaunchAgents() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return [
            "com.szu-netlogin.dorm-drcom",
            "com.fonsi.szu-dorm-drcom",
            "com.szu.autologin",
        ]
        .map { directory.appendingPathComponent("\($0).plist") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var versionDescription: String {
        let dictionary = Bundle.main.infoDictionary
        let version = dictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = dictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func mask(_ username: String) -> String {
        guard username != UserConfiguration.placeholder, username.count > 4 else {
            return username == UserConfiguration.placeholder ? "未设置" : "****"
        }
        return username.prefix(2) + String(repeating: "*", count: username.count - 4) + username.suffix(2)
    }
}
