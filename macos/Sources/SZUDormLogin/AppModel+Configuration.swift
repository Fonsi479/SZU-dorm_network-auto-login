import Foundation
import SZUNetCore

@MainActor
extension AppModel {
    func saveConfiguration(_ newConfiguration: AppConfiguration, password: String?) throws {
        var normalized = newConfiguration
        normalized.user.username = normalized.user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let password, !password.isEmpty {
            normalized.security.passwordSource = .keychain
        }
        _ = try normalized.validatedForLogin()
        try coordinator.configurationStore.save(normalized)
        if let password, !password.isEmpty {
            try coordinator.savePassword(password, configuration: normalized)
        }
        configuration = normalized
        updatePasswordState()
        logger.info("原生 Swift 配置已保存。")
        refreshStatus(allowAutoLogin: false)
    }

    func saveUsername(_ username: String) throws {
        let oldAccount = configuration.keychainAccount
        let oldPassword = try? coordinator.currentPassword(configuration: configuration)
        let updated = try coordinator.configurationStore.updateUsername(username)
        configuration = updated
        if let oldPassword, !oldPassword.isEmpty, oldAccount != updated.keychainAccount {
            try coordinator.savePassword(oldPassword, configuration: updated)
        }
        updatePasswordState()
        refreshStatus(allowAutoLogin: false)
    }

    func savePassword(_ password: String) throws {
        var current = try coordinator.currentConfiguration().validatedForLogin()
        if current.security.passwordSource != .keychain {
            current.security.passwordSource = .keychain
            try coordinator.configurationStore.save(current)
        }
        try coordinator.savePassword(password, configuration: current)
        configuration = current
        passwordSaved = true
        logger.info("密码已保存到 macOS 钥匙串。")
    }

    func loadConfiguration() {
        do {
            let result = try coordinator.configurationStore.load()
            configuration = result.configuration
            updatePasswordState()
            if let migratedFrom = result.migratedFrom {
                logger.info("已把旧版 YAML 配置迁移到原生 config.json：\(migratedFrom.path)")
                DispatchQueue.main.async { [weak self] in
                    self?.onConfigurationMigrated?(migratedFrom)
                }
            }
        } catch {
            statusText = "●  配置需要检查"
            statusTone = .failure
            statusDetail = error.localizedDescription
        }
    }

    func updatePasswordState() {
        passwordSaved = ((try? coordinator.currentPassword(configuration: configuration)) ?? nil)?
            .isEmpty == false
    }
}
