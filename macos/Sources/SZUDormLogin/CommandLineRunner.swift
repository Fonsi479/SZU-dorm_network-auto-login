import Darwin
import Foundation
import SZUNetCore

enum CommandLineRunner {
    static let version = "2.0.0"
    static let build = "1"

    static func run(_ command: String) -> Never {
        if command == "--version" {
            print("SZU Dorm Login \(version) (\(build)) · native Swift")
            exit(EXIT_SUCCESS)
        }

        Task {
            let logger = AppLogger()
            let coordinator = LoginCoordinator(logger: logger)
            let exitCode: Int32
            switch command {
            case "--self-test":
                exitCode = selfTest(coordinator: coordinator)
            case "--check-and-login":
                exitCode = report(await coordinator.checkAndLogin())
            case "--login":
                exitCode = report(await coordinator.loginNow())
            case "--logout":
                exitCode = report(await coordinator.logout())
            case "--probe":
                exitCode = await probe(coordinator: coordinator)
            case "--session-status":
                exitCode = await sessionStatus(coordinator: coordinator)
            case "--diagnostic-report":
                exitCode = await diagnosticReport(coordinator: coordinator, logger: logger)
            case "--launch-at-login-status":
                print("登录时启动：\(LaunchAtLoginController().description)")
                exitCode = EXIT_SUCCESS
            case "--auto-login-status":
                print(coordinator.pauseStore.isPaused ? "自动登录：已暂停" : "自动登录：已启用")
                exitCode = EXIT_SUCCESS
            case "--pause-auto-login":
                exitCode = updateAutoLogin(store: coordinator.pauseStore, enabled: false)
            case "--resume-auto-login":
                exitCode = updateAutoLogin(store: coordinator.pauseStore, enabled: true)
            default:
                fputs("未知参数：\(command)\n", stderr)
                fputs("可用参数：\(supportedCommands)\n", stderr)
                exitCode = 2
            }
            exit(exitCode)
        }
        dispatchMain()
    }

    private static func report(_ result: LoginActionResult) -> Int32 {
        print("\(result.title)：\(result.detail)")
        return result.isSuccess ? 0 : 1
    }

    private static func selfTest(coordinator: LoginCoordinator) -> Int32 {
        do {
            let result = try coordinator.configurationStore.load()
            _ = try result.configuration.validatedForLogin()
            print("Swift 核心：正常")
            print("配置解析：正常")
            print("Python 依赖：不需要")
            print("配置文件：\(coordinator.configurationStore.paths.configurationFile.path)")
            return EXIT_SUCCESS
        } catch {
            fputs("原生自检失败：\(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private static func probe(coordinator: LoginCoordinator) async -> Int32 {
        do {
            let (_, status, environment) = try await coordinator.probe()
            print("网络环境：\(environment.label)")
            print("网关可达：\(status.gatewayReachable ? "是" : "否")")
            print("校园网出口：\(status.campusInternetOK ? "可用" : "不可用")")
            print("门户会话：\(status.campusSessionState.rawValue)")
            print("源 IP：\(status.sourceIP.isEmpty ? "-" : status.sourceIP)")
            return EXIT_SUCCESS
        } catch {
            fputs("网络探测失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func sessionStatus(coordinator: LoginCoordinator) async -> Int32 {
        do {
            let (_, status, environment) = try await coordinator.sessionStatus()
            print("网络环境：\(environment.label)")
            print("网关可达：\(status.gatewayReachable ? "是" : "否")")
            print("门户会话：\(status.campusSessionState.rawValue)")
            print("源 IP：\(status.sourceIP.isEmpty ? "-" : status.sourceIP)")
            return EXIT_SUCCESS
        } catch {
            fputs("门户会话查询失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func diagnosticReport(
        coordinator: LoginCoordinator,
        logger: AppLogger
    ) async -> Int32 {
        do {
            let url = try await DiagnosticReportBuilder(
                coordinator: coordinator,
                logger: logger
            ).create()
            print("诊断报告已生成：\(url.path)")
            return EXIT_SUCCESS
        } catch {
            fputs("生成诊断报告失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func updateAutoLogin(store: PauseStore, enabled: Bool) -> Int32 {
        do {
            if enabled {
                try store.resume()
                print("自动登录：已恢复")
            } else {
                try store.pause()
                print("自动登录：已暂停")
            }
            return EXIT_SUCCESS
        } catch {
            fputs("修改自动登录状态失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static let supportedCommands = [
        "--version", "--self-test", "--ui-smoke-test", "--probe", "--session-status", "--login",
        "--check-and-login", "--logout", "--diagnostic-report",
        "--launch-at-login-status", "--auto-login-status",
        "--pause-auto-login", "--resume-auto-login",
    ].joined(separator: " ")
}
