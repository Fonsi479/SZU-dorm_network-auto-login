import Darwin
import Foundation
import SZUNETEmbedded
import SZUNetCore

enum CommandLineRunner {
    static let version = "2.0.0"
    static let build = "2"

    static func run(_ command: String) -> Never {
        if command == "--version" {
            print("SZU Dorm Login \(version) (\(build)) · native Swift")
            exit(EXIT_SUCCESS)
        }

        Task {
            let logger = AppLogger()
            let coordinator = LoginCoordinator(logger: logger)
            let embeddedRuntime = await makeEmbeddedRuntime(
                paths: coordinator.configurationStore.paths
            )
            let exitCode: Int32
            switch command {
            case "--self-test":
                exitCode = selfTest(coordinator: coordinator)
            case "--check-and-login":
                if let embeddedRuntime {
                    exitCode = report(await embeddedRuntime.login(automatic: true))
                } else {
                    exitCode = embeddedUnavailable()
                }
            case "--login":
                if let embeddedRuntime {
                    exitCode = report(await embeddedRuntime.login())
                } else {
                    exitCode = embeddedUnavailable()
                }
            case "--force-login":
                if let embeddedRuntime {
                    exitCode = report(await embeddedRuntime.forceLogin())
                } else {
                    exitCode = embeddedUnavailable()
                }
            case "--logout":
                if let embeddedRuntime {
                    exitCode = report(await embeddedRuntime.logout(providerID: .dorm))
                } else {
                    exitCode = embeddedUnavailable()
                }
            case "--probe":
                exitCode = if let embeddedRuntime {
                    await probe(runtime: embeddedRuntime)
                } else {
                    embeddedUnavailable()
                }
            case "--session-status":
                exitCode = if let embeddedRuntime {
                    await sessionStatus(runtime: embeddedRuntime)
                } else {
                    embeddedUnavailable()
                }
            case "--diagnostic-report":
                exitCode = await diagnosticReport(coordinator: coordinator, logger: logger)
            case "--launch-at-login-status":
                print("登录时启动：\(LaunchAtLoginController().description)")
                exitCode = EXIT_SUCCESS
            case "--auto-login-status":
                exitCode = if let embeddedRuntime {
                    await autoLoginStatus(runtime: embeddedRuntime)
                } else {
                    embeddedUnavailable()
                }
            case "--pause-auto-login":
                exitCode = if let embeddedRuntime {
                    await updateAutoLogin(runtime: embeddedRuntime, enabled: false)
                } else {
                    embeddedUnavailable()
                }
            case "--resume-auto-login":
                exitCode = if let embeddedRuntime {
                    await updateAutoLogin(runtime: embeddedRuntime, enabled: true)
                } else {
                    embeddedUnavailable()
                }
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

    private static func report(_ result: ProviderAuthResult) -> Int32 {
        print("校园网操作：\(result.errorCode ?? result.outcome.rawValue)")
        return result.outcome == .succeeded || result.outcome == .unchanged ? 0 : 1
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

    private static func probe(runtime: SZUNETEmbeddedRuntime) async -> Int32 {
        let snapshot = await runtime.refreshProduct()
        print("网络环境：\(snapshot.category.rawValue)")
        print("Dorm 会话：\(snapshot.dorm.lifecycle)")
        print("Teaching 会话：\(snapshot.teaching.lifecycle)")
        if let code = snapshot.lastErrorCode { print("错误码：\(code)") }
        return snapshot.lastErrorCode == nil ? EXIT_SUCCESS : 1
    }

    private static func sessionStatus(runtime: SZUNETEmbeddedRuntime) async -> Int32 {
        let snapshot = await runtime.refreshProduct()
        let lifecycle = switch snapshot.category {
        case .dorm: snapshot.dorm.lifecycle
        case .teaching: snapshot.teaching.lifecycle
        case .ambiguous, .nonCampus, .unknown: "unknown"
        }
        print("网络环境：\(snapshot.category.rawValue)")
        print("门户会话：\(lifecycle)")
        return snapshot.lastErrorCode == nil ? EXIT_SUCCESS : 1
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

    private static func updateAutoLogin(
        runtime: SZUNETEmbeddedRuntime,
        enabled: Bool
    ) async -> Int32 {
        do {
            if enabled {
                try await runtime.resumeAutomation()
                print("自动登录：已恢复")
            } else {
                try await runtime.pauseAutomation()
                print("自动登录：已暂停")
            }
            return EXIT_SUCCESS
        } catch {
            fputs("修改自动登录状态失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func autoLoginStatus(runtime: SZUNETEmbeddedRuntime) async -> Int32 {
        let snapshot = await runtime.currentProductSnapshot()
        print(snapshot.automaticEnabled ? "自动登录：已启用" : "自动登录：已暂停")
        return EXIT_SUCCESS
    }

    private static func makeEmbeddedRuntime(paths: AppPaths) async -> SZUNETEmbeddedRuntime? {
        let configuration = await AppModel.makeEmbeddedConfiguration(paths: paths)
        return try? SZUNETEmbeddedRuntime.make(configuration: configuration)
    }

    private static func embeddedUnavailable() -> Int32 {
        fputs("Embedded Runtime 初始化失败；未执行校园网操作。\n", stderr)
        return 2
    }

    private static let supportedCommands = [
        "--version", "--self-test", "--ui-smoke-test", "--probe", "--session-status", "--login", "--force-login",
        "--check-and-login", "--logout", "--diagnostic-report",
        "--launch-at-login-status", "--auto-login-status",
        "--pause-auto-login", "--resume-auto-login",
    ].joined(separator: " ")
}
