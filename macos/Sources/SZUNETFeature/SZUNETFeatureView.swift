import AppKit
import SwiftUI

public struct SZUNETFeatureView: View {
    @ObservedObject private var store: SZUNETFeatureStore
    @Binding private var featureEnabled: Bool
    @Binding private var autoLoginEnabled: Bool
    private let onFeatureSettingsChanged: () -> Void
    private let onAutoLoginChanged: (Bool) -> Void
    private let onResumeAutoLogin: () -> Void
    private let onNotice: (String) -> Void
    @State private var username = ""
    @State private var password = ""

    public init(
        store: SZUNETFeatureStore,
        featureEnabled: Binding<Bool>,
        autoLoginEnabled: Binding<Bool>,
        onFeatureSettingsChanged: @escaping () -> Void,
        onAutoLoginChanged: @escaping (Bool) -> Void,
        onResumeAutoLogin: @escaping () -> Void,
        onNotice: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        _featureEnabled = featureEnabled
        _autoLoginEnabled = autoLoginEnabled
        self.onFeatureSettingsChanged = onFeatureSettingsChanged
        self.onAutoLoginChanged = onAutoLoginChanged
        self.onResumeAutoLogin = onResumeAutoLogin
        self.onNotice = onNotice
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                moduleSwitchCard

                if featureEnabled {
                    statusGrid
                    providerCard
                    actionCard
                    accountCard
                    diagnosticsCard
                } else {
                    disabledCard
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadUsernameIfAvailable() }
        .onChange(of: store.snapshot.configuration?.username) { _ in
            loadUsernameIfAvailable()
        }
    }

    private var header: some View {
        SZUNETPageHeader(
            title: "校园网",
            subtitle: "按需启用宿舍区 Dr.COM / ePortal 登录。关闭模块时不会检查 Portal、读取密码或发送登录请求。",
            systemImage: "network"
        )
    }

    private var moduleSwitchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $featureEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用校园网模块")
                        .font(.headline)
                    Text("新安装默认关闭。关闭不会主动退出当前网络会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: featureEnabled) { _ in
                onFeatureSettingsChanged()
            }

            Divider()

            Toggle(isOn: Binding(
                get: { autoLoginEnabled },
                set: { onAutoLoginChanged($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动登录")
                        .font(.headline)
                    Text("只有宿舍网关可达且源 IP 位于校园网段时才会提交凭据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!featureEnabled)
        }
        .campusCard()
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statusCard(
                title: "网络环境",
                value: store.snapshot.environmentLabel,
                detail: environmentDetail,
                icon: environmentIcon,
                color: environmentColor
            )
            statusCard(
                title: "Portal 会话",
                value: portalLabel,
                detail: store.snapshot.manualLogoutSuppressed ? "手动退出抑制仍生效" : "状态由 SZUNET 会话复核得出",
                icon: portalIcon,
                color: portalColor
            )
            statusCard(
                title: "互联网",
                value: internetLabel,
                detail: "校园网检查失败不会停止 Codex 或远程服务",
                icon: internetIcon,
                color: internetColor
            )
            statusCard(
                title: "自动化",
                value: automationLabel,
                detail: nextAttemptLabel,
                icon: store.snapshot.manualLogoutSuppressed ? "hand.raised.fill" : "clock.arrow.2.circlepath",
                color: store.snapshot.manualLogoutSuppressed ? .orange : .blue
            )
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("明确操作")
                        .font(.title3.bold())
                    Text("手动登录与手动退出是独立路径，只会在你点击后执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理校园网操作")
                }
            }

            HStack(spacing: 10) {
                Button { store.manualLogin() } label: {
                    Label("手动登录", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isWorking)

                Button { store.manualLogout() } label: {
                    Label("手动退出", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(store.isWorking || store.snapshot.status.networkCategory != .dorm)

                Button { store.refresh() } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(store.isWorking)

                if store.snapshot.manualLogoutSuppressed && autoLoginEnabled {
                    Button("恢复自动登录") {
                        onResumeAutoLogin()
                    }
                    .disabled(store.isWorking)
                }
            }

            if let lastAction = store.snapshot.lastAction {
                Label(
                    [lastAction.title, lastAction.detail].filter { !$0.isEmpty }.joined(separator: "："),
                    systemImage: lastAction.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(lastAction.isSuccess ? .green : .orange)
                .textSelection(.enabled)
            }
        }
        .campusCard()
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider 状态")
                .font(.title3.bold())
            LabeledContent(
                "网络分类",
                value: store.snapshot.status.networkCategory?.rawValue ?? "unknown"
            )
            ForEach(store.snapshot.status.providers ?? [], id: \.provider) { provider in
                LabeledContent(
                    provider.provider == "dorm" ? "Dorm Dr.COM" : "Teaching SRun",
                    value: "\(provider.enabled ? "启用" : "停用") · \(provider.lifecycle) · \(provider.accountLabel.isEmpty ? "未设置标签" : provider.accountLabel)"
                )
            }
            Text("Teaching 退出操作不可用；自动登录仅在唯一、已验证的环境分类下执行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .campusCard()
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("账号与密码")
                    .font(.title3.bold())
                Text("密码只写入原 SZUNET 的 macOS 钥匙串项；界面不会读取或显示现有密码。留空可只更新账号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("校园网账号")
                        .frame(width: 92, alignment: .trailing)
                    TextField("学号或校园网账号", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("校园网账号")
                }
                GridRow {
                    Text("新密码")
                        .frame(width: 92, alignment: .trailing)
                    SecureField("留空则保持原密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("校园网新密码")
                }
            }

            Button("安全保存") {
                store.saveCredentials(username: username, password: password.isEmpty ? nil : password)
                password = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isWorking || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .campusCard()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("配置与诊断")
                .font(.title3.bold())
            LabeledContent("Portal 主机", value: store.snapshot.configuration?.portalHost ?? "未读取")
            LabeledContent("校园网源网段", value: "(store.snapshot.configuration?.sourceNetworkCount ?? 0) 条")
            LabeledContent("当前说明", value: store.snapshot.detail)
            if let errorCode = store.snapshot.status.errorCode {
                LabeledContent("脱敏错误码", value: errorCode)
            }
            Button("复制校园网诊断摘要") { copyDiagnostics() }
        }
        .font(.callout)
        .textSelection(.enabled)
        .campusCard()
    }

    private var disabledCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("校园网模块已关闭", systemImage: "power.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text(store.snapshot.detail)
                .foregroundStyle(.secondary)
            Text("Codex 额度、项目保护和远程代理功能仍可独立工作。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .campusCard()
    }

    private func statusCard(
        title: String,
        value: String,
        detail: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .szunetInsetSurface(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private var portalLabel: String {
        switch store.snapshot.status.portal {
        case .authenticated: "已认证"
        case .unauthenticated: "未认证"
        case .checking: "检查中"
        case .unknown: "未知"
        }
    }

    private var portalIcon: String {
        switch store.snapshot.status.portal {
        case .authenticated: "checkmark.circle.fill"
        case .unauthenticated: "person.crop.circle.badge.xmark"
        case .checking: "arrow.triangle.2.circlepath"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var portalColor: Color {
        switch store.snapshot.status.portal {
        case .authenticated: .green
        case .unauthenticated: .orange
        case .checking: .blue
        case .unknown: .secondary
        }
    }

    private var internetLabel: String {
        switch store.snapshot.status.internet {
        case .reachable: "可用"
        case .unreachable: "不可用"
        case .checking: "检查中"
        case .unknown: "未知"
        }
    }

    private var internetIcon: String {
        switch store.snapshot.status.internet {
        case .reachable: "network.badge.shield.half.filled"
        case .unreachable: "wifi.slash"
        case .checking: "network"
        case .unknown: "questionmark.circle"
        }
    }

    private var internetColor: Color {
        switch store.snapshot.status.internet {
        case .reachable: .green
        case .unreachable: .orange
        case .checking: .blue
        case .unknown: .secondary
        }
    }

    private var environmentDetail: String {
        switch store.snapshot.status.environment {
        case .eligible: "宿舍网关与校园网源 IP 双重门控已通过"
        case .ineligible: "不会自动提交校园网凭据"
        case .unknown: "尚未确认双重门控结果"
        }
    }

    private var environmentIcon: String {
        switch store.snapshot.status.environment {
        case .eligible: "checkmark.shield.fill"
        case .ineligible: "shield.slash.fill"
        case .unknown: "shield.lefthalf.filled"
        }
    }

    private var environmentColor: Color {
        switch store.snapshot.status.environment {
        case .eligible: .green
        case .ineligible: .orange
        case .unknown: .secondary
        }
    }

    private var automationLabel: String {
        if !autoLoginEnabled { return "已关闭" }
        return store.snapshot.manualLogoutSuppressed ? "手动暂停" : "已启用"
    }

    private var nextAttemptLabel: String {
        guard autoLoginEnabled else { return "手动登录和退出仍可使用" }
        guard !store.snapshot.manualLogoutSuppressed else { return "不会被其他模块刷新自动恢复" }
        guard let date = store.snapshot.nextAutomaticAttemptAt else { return "等待符合条件的离线状态" }
        return "下一次允许尝试：\(date.formatted(date: .omitted, time: .standard))"
    }

    private func loadUsernameIfAvailable() {
        guard username.isEmpty, let saved = store.snapshot.configuration?.username else { return }
        username = saved
    }

    private func copyDiagnostics() {
        let status = store.snapshot.status
        let lines = [
            "Codex 管家校园网诊断摘要",
            "模块：\(status.featureEnabled ? "启用" : "关闭")",
            "自动登录：\(status.autoLoginEnabled ? "启用" : "关闭")",
            "环境：\(status.environment.rawValue)",
            "Portal：\(status.portal.rawValue)",
            "互联网：\(status.internet.rawValue)",
            "手动退出抑制：\(store.snapshot.manualLogoutSuppressed ? "是" : "否")",
            "错误码：\(status.errorCode ?? "无")",
            "说明：\(store.snapshot.detail)",
            "说明：不含账号、密码、IP、Cookie 或令牌。",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        onNotice("校园网诊断摘要已复制（不含凭据）")
    }
}

private extension View {
    func campusCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 0.75)
            }
    }

    func szunetInsetSurface(cornerRadius: CGFloat = 10) -> some View {
        background(
            Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.42),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct SZUNETPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
