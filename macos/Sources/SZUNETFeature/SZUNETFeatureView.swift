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
                    connectionCard
                    automationCard
                    accountAndDiagnosticsCard
                    latestMessageCard
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
        .alert(
            "在线设备已达上限",
            isPresented: Binding(
                get: { store.forceLoginProvider != nil },
                set: { presented in
                    if !presented { store.cancelForceLogin() }
                }
            )
        ) {
            Button("取消", role: .cancel) { store.cancelForceLogin() }
            Button("强制切换", role: .destructive) { store.confirmForceLogin() }
        } message: {
            Text("当前账号已有 3 台设备在线。本次普通登录已阻止；确认后将由校园网服务端选择一台旧设备下线。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("校园网", systemImage: "network")
                .font(.largeTitle.bold())
            Text("登录、自动登录和连通性检测由独立 SZUNET App 安全执行。")
                .foregroundStyle(.secondary)
        }
    }

    private var adapterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("在“我的 Mac 管家”中显示并控制校园网", isOn: $adapterEnabled)
                .font(.headline)
            Text("关闭后不调用校园网 CLI；账号、密码和网络协议始终由独立 SZUNET App 管理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前连接")
                        .font(.title3.bold())
                    Text(statusSummary)
                        .font(.headline)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if store.isWorking { ProgressView().controlSize(.small) }
                Button("刷新状态") { store.refresh() }
                    .disabled(store.isWorking)
                Button("检查网络") { store.check() }
                    .disabled(store.isWorking)
            }

            if let status = store.snapshot.status {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 10
                ) {
                    statusValue("网络区域", networkLabel(status.networkContext))
                    statusValue("登录状态", sessionLabel(status.sessionState))
                    statusValue("当前线路", providerLabel(status.provider))
                    statusValue("自动登录", automationLabel(status.automaticEnabled))
                    statusValue("独立 App", ownerAppLabel(status.ownerAppRunning))
                    statusValue("在线设备", onlineDeviceLabel(status))
                    statusValue("最近更新", observedAtLabel(status.observedAt))
                }

                if let code = status.errorCode {
                    Label(errorMessage(code), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.orange)
                    Text("技术代码：\(code)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Label("正在等待独立 SZUNET App 返回状态。", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .featureCard()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("连接操作", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title3.bold())

            Picker("登录区域", selection: $selectedProvider) {
                Text("自动判断").tag(SZUNETCommandProvider.auto)
                Text("宿舍区").tag(SZUNETCommandProvider.dorm)
                Text("教学区").tag(SZUNETCommandProvider.teaching)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Button {
                    store.manualLogin(provider: selectedProvider)
                } label: {
                    Label("登录校园网", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.manualLogout()
                } label: {
                    Label("退出账号", systemImage: "rectangle.portrait.and.arrow.right")
                }

                Spacer()
            }
            .disabled(store.isWorking)

            Text("退出仅用于已验证的宿舍区会话；教学区退出在现场契约验证前保持禁用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("自动登录与连通性监测", systemImage: "bolt.horizontal.circle")
                .font(.title3.bold())

            controlRow(
                title: "自动登录",
                detail: automationDetail,
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                Toggle("", isOn: automationBinding)
                    .labelsHidden()
                    .disabled(store.isWorking || status?.automaticEnabled == nil)
                    .accessibilityLabel("自动登录")
            }

            Divider()

            controlRow(
                title: "测试网站连通性",
                detail: probeDetail,
                systemImage: "network.badge.shield.half.filled"
            ) {
                Toggle("", isOn: networkProbeBinding)
                    .labelsHidden()
                    .disabled(store.isWorking || status?.networkProbeEnabled == nil)
                    .accessibilityLabel("测试网站连通性")
            }

            HStack(spacing: 12) {
                Text("检测间隔")
                    .font(.callout.weight(.medium))
                Picker("检测间隔", selection: probeIntervalBinding) {
                    ForEach(SZUNETProbeInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(store.isWorking || status?.probeIntervalSeconds == nil)
                Spacer()
            }

            Text("这里控制独立 App 对已配置测试网址的周期性 HTTP 检测，不是 ICMP ping，也不会扫描或切换 VPN。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    private var accountAndDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("账号与维护", systemImage: "person.crop.circle.badge.gearshape")
                .font(.title3.bold())

            HStack(spacing: 10) {
                Button {
                    store.openSettings()
                } label: {
                    Label("修改账号或密码…", systemImage: "key")
                }

                Button {
                    store.diagnostics()
                } label: {
                    Label("刷新脱敏诊断", systemImage: "stethoscope")
                }
                Spacer()
            }
            .disabled(store.isWorking)

            Text("账号和密码会在独立 SZUNET 设置中修改；密码只写入 macOS 钥匙串，不经过“我的 Mac 管家”。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    @ViewBuilder
    private var latestMessageCard: some View {
        if let action = store.snapshot.lastAction {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近操作")
                    .font(.title3.bold())
                Label(
                    actionMessage(action),
                    systemImage: action.isSuccess
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(action.isSuccess ? Color.green : Color.orange)
                .textSelection(.enabled)
            }
            .featureCard()
        }
    }

    private var boundaryCard: some View {
        DisclosureGroup("技术与安全边界") {
            VStack(alignment: .leading, spacing: 8) {
                Text("独立 SZUNET App/CLI 是唯一认证与设置所有者。此页面只发送受限高层命令，不链接认证 Core、不读取账号密码、不创建第二套自动登录任务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Teaching 退出仍由独立 CLI 拒绝，直到校园现场契约完成验证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .accessibilityHint("展开查看认证所有权、凭据和教学区退出限制")
        .featureCard()
    }

    private var disabledCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("校园网控制已关闭", systemImage: "power.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text("不会启动独立校园网 CLI，也不会进行状态检查或登录操作。")
                .foregroundStyle(.secondary)
        }
        .featureCard()
    }

    private var status: SZUNETCommandResult? { store.snapshot.status }

    private var automationBinding: Binding<Bool> {
        Binding(
            get: { status?.automaticEnabled ?? false },
            set: { enabled in enabled ? store.resume() : store.pause() }
        )
    }

    private var networkProbeBinding: Binding<Bool> {
        Binding(
            get: { status?.networkProbeEnabled ?? false },
            set: { store.setNetworkProbeEnabled($0) }
        )
    }

    private var probeIntervalBinding: Binding<SZUNETProbeInterval> {
        Binding(
            get: {
                SZUNETProbeInterval(rawValue: status?.probeIntervalSeconds ?? 60)
                    ?? .oneMinute
            },
            set: { store.setProbeInterval($0) }
        )
    }

    private var automationDetail: String {
        switch status?.automaticEnabled {
        case true: "已开启；仅在网络环境和离线会话均确认后尝试登录。"
        case false: "已停止；不会后台发起登录。"
        case nil: "等待独立 App 返回设置。"
        }
    }

    private var probeDetail: String {
        switch status?.networkProbeEnabled {
        case true: "已开启；每 \(probeIntervalBinding.wrappedValue.label) 检查一次。"
        case false: "已关闭；周期性网站检测已停止。"
        case nil: "当前独立 App 版本尚未返回此设置。"
        }
    }

    private var statusSummary: String {
        guard let status else { return "等待状态" }
        if let code = status.errorCode { return errorMessage(code) }
        return "\(networkLabel(status.networkContext)) · \(sessionLabel(status.sessionState))"
    }

    private var statusColor: Color {
        guard let status else { return .secondary }
        if status.errorCode != nil { return .orange }
        return switch status.sessionState {
        case .online: .green
        case .offline: .orange
        case .unknown: .secondary
        case .blocked: .red
        }
    }

    private func controlRow<Control: View>(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            control()
        }
    }

    private func statusValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkLabel(_ context: SZUNETNetworkContext) -> String {
        switch context {
        case .dorm: "宿舍区校园网"
        case .teaching: "教学区校园网"
        case .otherCampus: "其他校园区域"
        case .nonCampus: "当前不是校园网"
        case .ambiguous: "网络区域有冲突"
        case .unknown: "网络区域待确认"
        }
    }

    private func sessionLabel(_ state: SZUNETSessionState) -> String {
        switch state {
        case .online: "已登录"
        case .offline: "未登录"
        case .unknown: "待确认"
        case .blocked: "操作受阻"
        }
    }

    private func providerLabel(_ provider: SZUNETResultProvider) -> String {
        switch provider {
        case .none: "尚未选择"
        case .auto: "自动判断"
        case .dorm: "宿舍区 Dorm"
        case .teaching: "教学区 Teaching"
        }
    }

    private func automationLabel(_ enabled: Bool?) -> String {
        switch enabled {
        case true: "已开启"
        case false: "已停止"
        case nil: "待确认"
        }
    }

    private func ownerAppLabel(_ running: Bool?) -> String {
        switch running {
        case true: "正在运行"
        case false: "未运行"
        case nil: "待确认"
        }
    }

    private func onlineDeviceLabel(_ status: SZUNETCommandResult) -> String {
        guard let count = status.onlineDeviceCount else { return "待确认" }
        return "\(count)/\(status.onlineDeviceLimit ?? 3)"
    }

    private func observedAtLabel(_ date: Date?) -> String {
        guard let date else { return "待确认" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func actionMessage(_ action: SZUNETCommandResult) -> String {
        if let code = action.errorCode { return errorMessage(code) }
        return switch action.outcome {
        case .succeeded: "操作已完成。"
        case .unchanged: "当前状态无需更改。"
        case .failed: "操作失败，请稍后重试。"
        case .cancelled: "操作已取消。"
        case .blocked: "安全条件未满足，操作未执行。"
        }
    }

    private func errorMessage(_ code: String) -> String {
        switch code {
        case "ADAPTER_CLI_UNAVAILABLE": "未找到独立 SZUNET App，请先安装或重新安装。"
        case "ADAPTER_TIMEOUT", "NET_TIMEOUT": "校园网状态检查超时，请稍后重试。"
        case "ENV_NON_CAMPUS": "当前不是校园网，未发送登录请求。"
        case "ENV_AMBIGUOUS": "网络区域证据有冲突，已停止自动操作。"
        case "CRED_MISSING": "尚未保存密码，请先修改账号或密码。"
        case "AUTH_BAD_PASSWORD": "账号或密码不正确，请更新后重试。"
        case "AUTH_DEVICE_LIMIT": "账号已有 3 台设备在线；普通登录已阻止，避免挤下其他设备。"
        case "NET_CAMPUS_EGRESS_UNAVAILABLE": "校园网会话仍在，但直连外网暂不可用；已避免重复登录。"
        case "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED": "强制切换仅适用于宿舍区 Dorm，Teaching 不会发送请求。"
        case "PROVIDER_DISABLED": "所选校园网区域尚未启用。"
        case "SRUN_LOGOUT_DISABLED": "教学区退出尚未开放，未发送退出请求。"
        case "OPERATION_IN_PROGRESS": "已有校园网操作正在进行，请稍候。"
        case "OPERATION_CANCELLED": "操作已取消。"
        default: "校园网操作未完成，请查看技术代码或刷新诊断。"
        }
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
