import Foundation
import SZUNETEmbedded
import SZUNetCore

@MainActor
extension AppModel {
    func saveCampusProviderConfiguration(_ newConfiguration: CampusProductConfiguration) throws {
        guard let embeddedRuntime else {
            throw SZUNetError.configuration(
                "Embedded Runtime 初始化失败；Provider 设置未保存。"
            )
        }
        let previousConfiguration = campusProviderConfiguration
        campusProviderConfiguration = newConfiguration
        Task { [weak self] in
            do {
                try await embeddedRuntime.updateProviderConfiguration(newConfiguration)
                self?.refreshCampusProduct(allowAutoLogin: false)
            } catch {
                if self?.campusProviderConfiguration == newConfiguration {
                    self?.campusProviderConfiguration = previousConfiguration
                }
                self?.logger.error("Embedded Provider 配置应用失败：\(error.localizedDescription)")
                self?.onResult?(
                    LoginActionResult(
                        outcome: .failed,
                        title: "Provider 设置保存失败",
                        detail: error.localizedDescription,
                        reason: "provider_settings_error"
                    ),
                    true
                )
            }
        }
    }

    func saveConfiguration(_ newConfiguration: AppConfiguration, password: String?) throws {
        var normalized = newConfiguration
        normalized.user.username = normalized.user.username.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try normalized.validatedForLogin()
        try coordinator.configurationStore.save(normalized)
        if let password, !password.isEmpty {
            try saveProviderPassword(password, providerID: .dorm)
        }
        configuration = normalized
        logger.info("原生 Swift 配置已保存。")
        refreshStatus(allowAutoLogin: false)
    }

    func saveUsername(_ username: String) throws {
        let updated = try coordinator.configurationStore.updateUsername(username)
        configuration = updated
        var providers = campusProviderConfiguration
        providers.dorm.accountLabel = username.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveCampusProviderConfiguration(providers)
        refreshStatus(allowAutoLogin: false)
    }

    func savePassword(_ password: String) throws {
        try saveProviderPassword(password, providerID: .dorm)
    }

    func saveProviderPassword(
        _ password: String,
        providerID: CampusProviderID,
        providerConfiguration: CampusProductConfiguration? = nil
    ) throws {
        guard !password.isEmpty else {
            throw SZUNetError.configuration("密码不能为空。")
        }
        let settings = (providerConfiguration ?? campusProviderConfiguration).settings(
            for: providerID
        )
        guard !settings.credentialReference.isEmpty else {
            throw SZUNetError.configuration("credential reference 不能为空。")
        }
        guard let embeddedRuntime else {
            throw SZUNetError.configuration(
                "Embedded Runtime 初始化失败；Provider 密码未保存。"
            )
        }
        Task { [weak self] in
            do {
                if let providerConfiguration {
                    try await embeddedRuntime.updateProviderConfiguration(providerConfiguration)
                    self?.campusProviderConfiguration = providerConfiguration
                }
                try await embeddedRuntime.savePassword(password, provider: providerID)
                if providerID == .dorm { self?.passwordSaved = true }
                self?.logger.info("\(providerID.rawValue) Provider 密码已通过 Embedded Runtime 保存。")
            } catch {
                self?.onResult?(
                    LoginActionResult(
                        outcome: .failed,
                        title: "保存 Provider 密码失败",
                        detail: error.localizedDescription,
                        reason: "provider_credential_error"
                    ),
                    true
                )
            }
        }
    }

    func loadConfiguration() {
        do {
            let result = try coordinator.configurationStore.load()
            configuration = result.configuration
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

}
