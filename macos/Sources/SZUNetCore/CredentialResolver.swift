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
            return password?.isEmpty == false
                ? password
                : Self.privateFilePassword(path: configuration.security.privateFilePath)
        case .environment:
            return ProcessInfo.processInfo.environment[configuration.security.passwordEnvironmentName]
        case .privateFile:
            return Self.privateFilePassword(path: configuration.security.privateFilePath)
        }
    }

    private static func privateFilePassword(path: String) -> String? {
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":"),
                  trimmed[..<colon].trimmingCharacters(in: .whitespaces) == "password" else {
                continue
            }
            var value = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.first == "\"" || value.first == "'"),
               value.last == value.first {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return text.components(separatedBy: .newlines).first
    }
}
