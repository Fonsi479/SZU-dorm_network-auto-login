import Foundation
import Security

public protocol CredentialStoring {
    func password(service: String, account: String) throws -> String?
    func setPassword(_ password: String, service: String, account: String) throws
    func deletePassword(service: String, account: String) throws
}

public final class KeychainStore: CredentialStoring {
    public init() {}

    public func password(service: String, account: String) throws -> String? {
        guard !service.isEmpty, !account.isEmpty else { return nil }
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SZUNetError.credential("钥匙串中的密码格式无法读取。")
        }
        return value
    }

    public func setPassword(_ password: String, service: String, account: String) throws {
        guard !service.isEmpty else {
            throw SZUNetError.credential("钥匙串服务名不能为空。")
        }
        guard !account.isEmpty else {
            throw SZUNetError.credential("请先设置校园网账号。")
        }
        guard !password.isEmpty else {
            throw SZUNetError.credential("密码不能为空。")
        }

        let query = baseQuery(service: service, account: account)
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    public func deletePassword(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ status: OSStatus) -> SZUNetError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
        return .credential("无法访问 macOS 钥匙串：\(detail)")
    }
}

public extension AppConfiguration {
    var keychainAccount: String {
        let configured = security.keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? user.username.trimmingCharacters(in: .whitespacesAndNewlines) : configured
    }
}
