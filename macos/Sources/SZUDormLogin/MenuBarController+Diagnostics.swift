import AppKit
import SZUNetCore

@MainActor
extension MenuBarController {
    @objc func generateDiagnosticReport() {
        let builder = DiagnosticReportBuilder(
            coordinator: model.coordinator,
            logger: model.logger,
            launchAtLoginStatus: { [weak model] in
                model?.launchAtLogin.description ?? "未知"
            }
        )
        Task {
            do {
                let url = try await builder.create()
                NSWorkspace.shared.open(url)
                present(
                    result: LoginActionResult(
                        outcome: .unchanged,
                        title: "诊断报告已生成",
                        detail: url.path
                    ),
                    showAlert: false
                )
            } catch {
                showError(title: "生成诊断报告失败", detail: error.localizedDescription)
            }
        }
    }

    @objc func openConfiguration() {
        NSWorkspace.shared.open(model.coordinator.configurationStore.paths.configurationFile)
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(model.coordinator.configurationStore.paths.logDirectory)
    }

    @objc func resetPause() {
        model.resetPauseState()
    }

    @objc func runSelfCheck() {
        do {
            let configuration = try model.coordinator.currentConfiguration()
            _ = try configuration.validatedForLogin()
            let credential = model.passwordSaved ? "已保存" : "未保存"
            let detail = "Swift 核心：正常\n配置：正常\n钥匙串密码：\(credential)\nPython 依赖：不需要"
            let alert = NSAlert()
            alert.messageText = "原生自检完成"
            alert.informativeText = detail
            alert.alertStyle = .informational
            alert.runModal()
        } catch {
            showError(title: "原生自检未通过", detail: error.localizedDescription)
        }
    }

    @objc func quit() {
        model.stop()
        NSApp.terminate(nil)
    }

    func present(result: LoginActionResult, showAlert: Bool) {
        UserNotificationPresenter.post(title: result.title, body: result.detail)
        if showAlert {
            showError(title: result.title, detail: result.detail)
        }
    }

    func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
