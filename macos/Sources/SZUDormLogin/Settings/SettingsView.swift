import SwiftUI
import SZUNetCore

struct SettingsView: View {
    @State private var configuration: AppConfiguration
    @State private var password = ""
    @State private var errorMessage = ""

    let passwordSaved: Bool
    let configurationPath: String
    let onSave: (AppConfiguration, String?) throws -> Void
    let onCancel: () -> Void

    init(
        configuration: AppConfiguration,
        passwordSaved: Bool,
        configurationPath: String,
        onSave: @escaping (AppConfiguration, String?) throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        _configuration = State(initialValue: configuration)
        self.passwordSaved = passwordSaved
        self.configurationPath = configurationPath
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    accountSection
                    portalSection
                    networkSection
                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Text(
                        "配置保存到 \(configurationPath)。"
                            + "密码只写入 macOS 钥匙串，不写入配置文件。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 600, idealHeight: 720)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("原生 macOS 设置")
                    .font(.title2.bold())
                Text("Swift 网络核心 · Keychain 凭据 · Dr.COM / ePortal")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        GroupBox("账号与钥匙串") {
            VStack(alignment: .leading, spacing: 10) {
                field("校园网账号", text: $configuration.user.username)
                HStack {
                    Text("校园网密码")
                        .frame(width: 105, alignment: .trailing)
                    SecureField(
                        passwordSaved ? "已保存；留空保持原密码" : "请输入校园网密码",
                        text: $password
                    )
                    .textFieldStyle(.roundedBorder)
                }
                field("钥匙串服务", text: $configuration.security.keychainService)
            }
            .padding(.top, 6)
        }
    }

    private var portalSection: some View {
        GroupBox("Dr.COM 门户") {
            VStack(alignment: .leading, spacing: 10) {
                field("登录地址", text: $configuration.auth.loginURL)
                field(
                    "退出地址",
                    text: $configuration.auth.logoutURL,
                    prompt: "留空时从登录地址推导"
                )
                field(
                    "门户退出页",
                    text: $configuration.auth.logoutPageURL,
                    prompt: "留空时自动推导"
                )
                field("账号前缀", text: $configuration.auth.accountPrefix)
                HStack {
                    Text("请求超时")
                        .frame(width: 105, alignment: .trailing)
                    Stepper(
                        "\(configuration.auth.timeoutSeconds) 秒",
                        value: $configuration.auth.timeoutSeconds,
                        in: 1...60
                    )
                    Spacer()
                }
            }
            .padding(.top, 6)
        }
    }

    private var networkSection: some View {
        GroupBox("网络识别与安全边界") {
            VStack(alignment: .leading, spacing: 10) {
                field(
                    "宿舍区网关",
                    text: arrayBinding(
                        get: { configuration.network.gatewayHosts },
                        set: { configuration.network.gatewayHosts = $0 }
                    ),
                    prompt: "每行一个地址"
                )
                field(
                    "校园网网段",
                    text: arrayBinding(
                        get: { configuration.network.campusSourceNetworks },
                        set: { configuration.network.campusSourceNetworks = $0 }
                    ),
                    prompt: "例如 172.16.0.0/12"
                )
                field(
                    "宿舍 Wi-Fi",
                    text: arrayBinding(
                        get: { configuration.network.campusWiFiNames },
                        set: { configuration.network.campusWiFiNames = $0 }
                    ),
                    prompt: "每行一个名称"
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("联网检测地址（至少两个，每行一个）")
                        .font(.callout)
                    TextEditor(text: arrayBinding(
                        get: { configuration.network.testURLs },
                        set: { configuration.network.testURLs = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 78)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                }
            }
            .padding(.top, 6)
        }
    }

    private func save() {
        do {
            errorMessage = ""
            try onSave(configuration, password.isEmpty ? nil : password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        prompt: String = ""
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 105, alignment: .trailing)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func arrayBinding(
        get: @escaping () -> [String],
        set: @escaping ([String]) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get().joined(separator: "\n") },
            set: { value in
                set(
                    value.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
        )
    }
}
