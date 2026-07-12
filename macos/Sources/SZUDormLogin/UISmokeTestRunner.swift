import AppKit
import Darwin
import SZUNetCore

enum UISmokeTestRunner {
    @MainActor
    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel(logger: AppLogger())
        let controller = MenuBarController(model: model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let issues = controller.smokeTestIssues()
        model.stop()
        withExtendedLifetime(controller) {}

        guard issues.isEmpty else {
            fputs("状态栏 UI 检查失败：\(issues.joined(separator: "；"))\n", stderr)
            exit(EXIT_FAILURE)
        }
        print("AppKit/SwiftUI 状态栏初始化：正常")
        exit(EXIT_SUCCESS)
    }
}
