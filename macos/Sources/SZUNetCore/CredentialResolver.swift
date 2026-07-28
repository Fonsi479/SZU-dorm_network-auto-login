import Foundation

struct CredentialResolver {
    let store: CredentialStoring

    func password(for configuration: AppConfiguration) throws -> String? {
        switch configuration.security.passwordSource {
        case .keychain:
            let password = try store.password(
                service: configuration.security.keychainService,
                account: configuration.keychainAccount
            )
            if password?.isEmpty == false { return password }
            if Self.legacyPrivateFileExists(path: configuration.security.privateFilePath) {
                throw SZUNetError.credential("检测到旧密码文件；请在应用中明确迁移到 macOS 钥匙串。")
            }
            return nil
        case .environment, .privateFile:
            throw SZUNetError.credential("旧明文密码来源已停用；请明确迁移到 macOS 钥匙串。")
        }
    }

    private static func legacyPrivateFileExists(path: String) -> Bool {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        return FileManager.default.fileExists(atPath: expanded)
    }
}
