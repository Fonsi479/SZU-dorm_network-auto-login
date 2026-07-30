import SwiftUI

public struct SZUNETFeatureView: View {
    private static let presentationConsumerID = "SZUNETFeatureView.detail"

    @ObservedObject private var store: SZUNETFeatureStore
    @Binding private var adapterEnabled: Bool
    private let onAdapterEnabledChanged: (Bool) -> Void
    @State private var selectedProvider = SZUNETCommandProvider.auto

    public init(
        store: SZUNETFeatureStore,
        adapterEnabled: Binding<Bool>,
        onAdapterEnabledChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.store = store
        _adapterEnabled = adapterEnabled
        self.onAdapterEnabledChanged = onAdapterEnabledChanged
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                adapterCard
                if adapterEnabled {
                    statusCard
                    actionCard
                    boundaryCard
                } else {
                    disabledCard
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.start(adapterEnabled: adapterEnabled)
            store.setPresentationActivity(
                .detailVisible,
                consumerID: Self.presentationConsumerID
            )
        }
        .onDisappear {
            store.setPresentationActivity(
                .inactive,
                consumerID: Self.presentationConsumerID
            )
        }
        .onChange(of: adapterEnabled) { value in
            store.setAdapterEnabled(value)
            onAdapterEnabledChanged(value)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("校园网", systemImage: "network")
                .font(.largeTitle.bold())
            Text("通过独立 SZUNET App 的 JSON CLI 显示脱敏状态并转发高层命令。")
                .foregroundStyle(.secondary)
        }
    }

    private var adapterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("在当前宿主中启用 SZUNET 消费端", isOn: $adapterEnabled)
                .font(.headline)
            Text("此开关只控制状态显示和 CLI 调用，不修改独立 App 的 Provider、凭据、设置或登录项。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("脱敏状态")
                    .font(.title3.bold())
                Spacer()
                if store.isWorking { ProgressView().controlSize(.small) }
                Button("刷新") { store.refresh() }
                    .disabled(store.isWorking)
                Button("检查") { store.check() }
                    .disabled(store.isWorking)
            }

            if let status = store.snapshot.status {
                LabeledContent("网络分类", value: status.networkContext.rawValue)
                LabeledContent("会话状态", value: status.sessionState.rawValue)
                LabeledContent("Provider", value: status.provider.rawValue)
                LabeledContent("结果", value: status.outcome.rawValue)
                if let code = status.errorCode {
                    LabeledContent("错误码", value: code)
                }
            } else {
                Text("尚未取得独立 CLI 状态。")
                    .foregroundStyle(.secondary)
            }

            Text(store.snapshot.detail)
                .font(.callout)
                .textSelection(.enabled)
        }
        .featureCard()
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高层命令")
                .font(.title3.bold())

            Picker("登录目标", selection: $selectedProvider) {
                Text("自动判断").tag(SZUNETCommandProvider.auto)
                Text("Dorm").tag(SZUNETCommandProvider.dorm)
                Text("Teaching").tag(SZUNETCommandProvider.teaching)
            }
            .pickerStyle(.segmented)

            HStack {
                Button("明确登录") { store.manualLogin(provider: selectedProvider) }
                    .buttonStyle(.borderedProminent)
                Button("Dorm 退出") { store.manualLogout() }
                Button("暂停自动化") { store.pause() }
                Button("恢复自动化") { store.resume() }
            }
            .disabled(store.isWorking)

            HStack {
                Button("打开独立 App 设置") { store.openSettings() }
                Button("刷新脱敏诊断") { store.diagnostics() }
            }
            .disabled(store.isWorking)

            if let action = store.snapshot.lastAction {
                Label(
                    action.errorCode ?? action.outcome.rawValue,
                    systemImage: action.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(action.isSuccess ? .green : .orange)
                .textSelection(.enabled)
            }
        }
        .featureCard()
    }

    private var boundaryCard: some View {
        DisclosureGroup("技术与安全边界") {
            VStack(alignment: .leading, spacing: 8) {
                Text("独立 SZUNET App/CLI 是唯一认证与设置所有者。此视图不链接认证 Core，不保存账号材料，不创建 Provider/Coordinator，也不自行调度登录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Teaching 退出仍由独立 CLI 拒绝，直到校园现场契约完成验证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .accessibilityHint("展开查看认证所有权、凭据和 Teaching 退出限制")
        .featureCard()
    }

    private var disabledCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("消费端已关闭", systemImage: "power.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text(store.snapshot.detail)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }
}

private extension View {
    func featureCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            )
    }
}
