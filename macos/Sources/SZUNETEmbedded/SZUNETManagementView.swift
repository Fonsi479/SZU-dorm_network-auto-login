import AppKit
import Foundation
import SwiftUI
import SZUNETFeature
import SZUNetCore

public struct SZUNETManagementView: View {
    @StateObject private var model: SZUNETManagementModel
    @State private var showsAccountMaintenance = false
    @State private var showsSecurityBoundary = false

    public init(runtime: SZUNETEmbeddedRuntime) {
        _model = StateObject(wrappedValue: SZUNETManagementModel(runtime: runtime))
    }

    private init(visualReference: Void) {
        _model = StateObject(wrappedValue: SZUNETManagementModel.visualReference())
    }

    /// Deterministic, offline-only surface used by the host's visual acceptance
    /// hook. It never constructs a runtime, reads credentials or probes a network.
    public static var visualReferencePreview: SZUNETManagementView {
        SZUNETManagementView(visualReference: ())
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard(horizontal: proxy.size.width >= 800)
                    primaryGrid(horizontal: proxy.size.width >= 760)
                    secondaryGrid(horizontal: proxy.size.width >= 760)
                    securityBoundaryCard
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1_190, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(CampusTheme.canvas)
        .task { await model.load() }
        .overlay {
            if model.showsVisualDeviceLimitConfirmation {
                visualDeviceLimitConfirmation
            }
        }
        .sheet(isPresented: $showsAccountMaintenance) {
            accountMaintenanceSheet
        }
        .sheet(isPresented: $showsSecurityBoundary) {
            securityBoundarySheet
        }
        .alert(
            "在线设备已达上限",
            isPresented: Binding(
                get: {
                    !model.showsVisualDeviceLimitConfirmation
                        && model.forceLoginProvider != nil
                },
                set: { presented in
                    if !presented { model.cancelForceLogin() }
                }
            )
        ) {
            Button("取消", role: .cancel) { model.cancelForceLogin() }
            Button("强制切换", role: .destructive) { model.confirmForceLogin() }
        } message: {
            Text("当前账号已有 3 台设备在线。本次普通登录已阻止；确认后将由校园网服务端选择一台旧设备下线。")
        }
    }

    /// SwiftUI system alerts are not captured by an offscreen `NSHostingView`.
    /// Render the same confirmation as a fixture-only overlay so light/dark
    /// visual acceptance proves the warning copy and both choices are present.
    private var visualDeviceLimitConfirmation: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Label("在线设备已达上限", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(CampusTheme.warning)
                Text("当前账号已有 3 台设备在线。本次普通登录已阻止；确认后将由校园网服务端选择一台旧设备下线。")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("取消") { model.cancelForceLogin() }
                    Button("强制切换", role: .destructive) { model.confirmForceLogin() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(width: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(CampusTheme.accent)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("校园网")
                    .font(.system(size: 24, weight: .bold))
                Text("登录、自动登录和连通性检测由内置开源 SZUNET Runtime 安全执行")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 14)

            HStack(spacing: 7) {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: model.headerBadgeIcon)
                }
                Text(model.headerBadgeText)
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(model.statusTone.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(model.statusTone.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statusCard(horizontal: Bool) -> some View {
        Group {
            if horizontal {
                HStack(alignment: .top, spacing: 0) {
                    currentStatusColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    CampusVerticalDivider()
                    quickActionsColumn
                        .frame(width: 230, alignment: .topLeading)
                    CampusVerticalDivider()
                    guidanceColumn
                        .frame(width: 270, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    currentStatusColumn
                    Divider()
                    quickActionsColumn
                    Divider()
                    guidanceColumn
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CampusTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CampusTheme.border, lineWidth: 1)
        }
        .shadow(color: CampusTheme.shadow, radius: 9, y: 3)
    }

    private var currentStatusColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            CampusSectionHeader(systemImage: "antenna.radiowaves.left.and.right", title: "当前状态")

            HStack(alignment: .top, spacing: 13) {
                Image(systemName: model.statusTone.largeSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(model.statusTone.foreground)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.currentStatusTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                    Text(model.currentStatusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if let code = model.technicalCode {
                Text("技术代码：\(code)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            } else {
                Text("最近检测：\(model.lastCheckedText)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.trailing, 18)
    }

    private var quickActionsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速操作")
                .font(.system(size: 15, weight: .semibold))

            Button {
                model.run(.status)
            } label: {
                Label("刷新状态", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CampusFilledButtonStyle(color: CampusTheme.accent))
            .disabled(model.isWorking)

            Button {
                model.run(.check)
            } label: {
                Label("检查网络", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CampusOutlinedButtonStyle())
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 18)
    }

    private var guidanceColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.guidanceTitle)
                .font(.system(size: 15, weight: .semibold))

            ForEach(Array(model.guidanceSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .frame(width: 14, alignment: .trailing)
                    Text(step)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("查看安全边界  →") {
                showsSecurityBoundary = true
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CampusTheme.accent)
            .padding(.top, 5)
        }
        .padding(.leading, 18)
    }

    @ViewBuilder
    private func primaryGrid(horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .top, spacing: 18) {
                connectionCard
                automationCard
            }
        } else {
            VStack(spacing: 18) {
                connectionCard
                automationCard
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CampusSectionHeader(systemImage: "link", title: "连接操作")

            HStack(spacing: 12) {
                Text("登录区域")
                    .font(.callout.weight(.medium))
                    .fixedSize()
                Picker("登录区域", selection: $model.selectedProvider) {
                    Text("自动判断").tag(SZUNETCommandProvider.auto)
                    Text("宿舍区").tag(SZUNETCommandProvider.dorm)
                    Text("教学区").tag(SZUNETCommandProvider.teaching)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Button {
                    model.run(.login, provider: model.selectedProvider)
                } label: {
                    Label("登录校园网", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CampusFilledButtonStyle(color: CampusTheme.success))

                Button {
                    model.run(.logout, provider: model.selectedProvider)
                } label: {
                    Label("退出账号", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CampusOutlinedButtonStyle())
            }
            .disabled(model.isWorking)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("退出仅用于已验证的宿舍区会话；Teaching 退出在现场验证前仍安全阻止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .campusCard(minHeight: 210)
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CampusSectionHeader(systemImage: "point.3.connected.trianglepath.dotted", title: "自动登录与连通性监测")
                .padding(.bottom, 10)

            CampusSettingRow(
                systemImage: "bell.badge",
                title: "自动登录",
                detail: model.autoLoginDetail
            ) {
                Toggle("自动登录", isOn: Binding(
                    get: { model.automaticEnabled },
                    set: { model.run($0 ? .resume : .pause) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isWorking || !model.hasAutomationState)
            }

            Divider()

            CampusSettingRow(
                systemImage: "globe.badge.chevron.backward",
                title: "测试网站连通性",
                detail: "检测当前网络是否可以访问互联网"
            ) {
                Button("立即检测") { model.run(.check) }
                    .buttonStyle(CampusCompactButtonStyle())
                    .disabled(model.isWorking)
            }

            Divider()

            CampusSettingRow(
                systemImage: "slider.horizontal.3",
                title: "检测间隔",
                detail: "设置连通性检测的时间间隔"
            ) {
                Picker("检测间隔", selection: Binding(
                    get: { model.probeInterval },
                    set: { model.setProbeInterval($0) }
                )) {
                    ForEach(SZUNETProbeInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 135)
                .disabled(model.isWorking)
            }

            HStack(spacing: 8) {
                Button {
                    model.run(model.networkProbeEnabled ? .disableProbe : .enableProbe)
                } label: {
                    Label(
                        model.networkProbeEnabled ? "连通性监测已开启" : "连通性监测已关闭",
                        systemImage: model.networkProbeEnabled ? "checkmark.circle.fill" : "pause.circle"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.networkProbeEnabled ? CampusTheme.accent : .secondary)
                .disabled(model.isWorking || !model.hasProbeState)

                Spacer(minLength: 8)

                Text(model.ownershipText)
                    .lineLimit(1)

                if model.isCurrentOwner {
                    Button("释放") { Task { await model.releaseOwnership() } }
                        .buttonStyle(.link)
                        .disabled(model.isWorking)
                } else if model.canTakeOwnership {
                    Button("转移给此模块") { Task { await model.takeOwnership() } }
                        .buttonStyle(.link)
                        .disabled(model.isWorking)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 11)

            if let warning = model.ownershipWarning {
                Text(warning)
                    .font(.caption.monospaced())
                    .foregroundStyle(CampusTheme.warning)
                    .padding(.top, 5)
            }
        }
        .campusCard(minHeight: 210)
    }

    @ViewBuilder
    private func secondaryGrid(horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .top, spacing: 18) {
                accountMaintenanceCard
                recentOperationsCard
                statusOverviewCard
            }
        } else {
            VStack(spacing: 18) {
                accountMaintenanceCard
                recentOperationsCard
                statusOverviewCard
            }
        }
    }

    private var accountMaintenanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CampusSectionHeader(systemImage: "waveform.circle", title: "账号与维护")
                .padding(.bottom, 9)

            CampusActionRow(
                systemImage: "person.crop.circle.badge.checkmark",
                title: "修改账号或密码",
                detail: model.accountSummary
            ) {
                showsAccountMaintenance = true
            }

            Divider()

            CampusActionRow(
                systemImage: "externaldrive.connected.to.line.below",
                title: "刷新网络诊断",
                detail: "重新收集脱敏网络诊断信息"
            ) {
                model.run(.diagnostics)
            }
        }
        .campusCard(minHeight: 154)
    }

    private var recentOperationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CampusSectionHeader(systemImage: "clock", title: "最近操作")

            ForEach(model.recentOperations.prefix(2)) { operation in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: operation.tone.smallSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(operation.tone.foreground)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(operation.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(operation.tone.valueForeground)
                            .lineLimit(1)
                        Text(operation.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(operation.timeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(11)
                .background(operation.tone.fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(operation.tone.foreground.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .campusCard(minHeight: 154)
    }

    private var statusOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CampusSectionHeader(systemImage: "scope", title: "状态概览")

            CampusStatusRow(label: "网络区域", value: model.networkRegionText)
            CampusStatusRow(label: "登录状态", value: model.sessionText)
            CampusStatusRow(label: "在线设备", value: model.onlineDeviceText)
            CampusStatusRow(label: "自动登录", value: model.automaticText)
            CampusStatusRow(label: "最近检测", value: model.lastCheckedText)
            CampusStatusRow(label: "IP 地址", value: "—")
        }
        .campusCard(minHeight: 154)
    }

    private var securityBoundaryCard: some View {
        Button {
            showsSecurityBoundary = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "lock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("技术与安全边界")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("网络操作由内置开源 Runtime 执行；密码只进入 macOS 钥匙串，不写入共享配置或诊断。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .campusCard(minHeight: 72)
    }

    private var accountMaintenanceSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("账号与 Provider")
                        .font(.title2.bold())
                    Text("密码留空表示保持现有钥匙串内容不变。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { showsAccountMaintenance = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    providerEditor(
                        title: "宿舍区 Dorm",
                        enabled: $model.dormEnabled,
                        account: $model.dormAccount,
                        password: $model.dormPassword
                    )
                    providerEditor(
                        title: "教学区 Teaching",
                        enabled: $model.teachingEnabled,
                        account: $model.teachingAccount,
                        password: $model.teachingPassword
                    )

                    Text(model.credentialDisclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("保存设置") {
                            Task { await model.saveProviders() }
                        }
                        .buttonStyle(CampusFilledButtonStyle(color: CampusTheme.accent))
                        .disabled(model.isWorking)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 520)
        .background(CampusTheme.canvas)
    }

    private func providerEditor(
        title: String,
        enabled: Binding<Bool>,
        account: Binding<String>,
        password: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Toggle(title, isOn: enabled)
                .font(.headline)
            TextField("账号", text: account)
                .textFieldStyle(.roundedBorder)
            SecureField("新密码（留空则不修改）", text: password)
                .textFieldStyle(.roundedBorder)
        }
        .campusCard(minHeight: 0)
    }

    private var securityBoundarySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(CampusTheme.accent)
                Text("技术与安全边界")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { showsSecurityBoundary = false }
                    .keyboardShortcut(.cancelAction)
            }

            CampusBoundaryRow(
                title: "内置执行",
                detail: "我的 Mac 管家直接链接 SZUNETEmbedded，不需要独立 App 或 CLI 才能工作。"
            )
            CampusBoundaryRow(
                title: "凭据隔离",
                detail: model.credentialDisclosure
            )
            CampusBoundaryRow(
                title: "唯一自动化所有者",
                detail: "后台认证前会再次核验所有权，避免独立 App 与内置模块重复调度。"
            )
            CampusBoundaryRow(
                title: "Teaching 安全门控",
                detail: "未经现场验证的 Teaching 退出继续返回 SRUN_LOGOUT_DISABLED，不发送退出请求。"
            )

            Spacer()
        }
        .padding(24)
        .frame(width: 560, height: 430)
        .background(CampusTheme.canvas)
    }
}

@MainActor
final class SZUNETManagementModel: ObservableObject {
    private let runtime: SZUNETEmbeddedRuntime?
    private let isVisualReference: Bool
    private let credentialDisclosureText: String
    private var providerConfiguration = CampusProductConfiguration.default

    @Published var result: SZUNETCommandResult?
    @Published var ownership: CampusAutomationOwnershipSnapshot?
    @Published var selectedProvider = SZUNETCommandProvider.auto
    @Published var dormEnabled = true
    @Published var dormAccount = ""
    @Published var dormPassword = ""
    @Published var teachingEnabled = false
    @Published var teachingAccount = ""
    @Published var teachingPassword = ""
    @Published var isWorking = false
    @Published var message: String?
    @Published var recentOperations: [CampusRecentOperation] = []
    /// Selected provider awaiting explicit confirmation after a normal login
    /// was blocked by the Dorm three-device limit.
    @Published private(set) var forceLoginProvider: SZUNETCommandProvider?

    init(runtime: SZUNETEmbeddedRuntime) {
        self.runtime = runtime
        isVisualReference = false
        credentialDisclosureText = runtime.configuration.credentialMode.sharesCredentialsWithOfficialClients
            ? "凭据保存到官方客户端共享的 macOS 钥匙串访问组。"
            : "本地构建不会与官方客户端共享凭据；密码只写入当前钥匙串范围。"
    }

    private init(visualReference: Bool) {
        runtime = nil
        isVisualReference = visualReference
        credentialDisclosureText = "视觉验收使用离线固定状态；正式版本的密码只写入 macOS 钥匙串。"
        result = SZUNETCommandResult(
            requestId: "visual-reference",
            outcome: .unchanged,
            provider: .auto,
            networkContext: .unknown,
            sessionState: .offline,
            automaticEnabled: true,
            ownerAppRunning: true,
            networkProbeEnabled: true,
            probeIntervalSeconds: 60,
            onlineDeviceCount: 3,
            onlineDeviceLimit: 3,
            observedAt: Date()
        )
        // The deterministic visual fixture represents the exact safety state
        // this release adds: this Mac is offline, the account is at 3/3, and
        // the ordinary login has stopped pending explicit confirmation.
        forceLoginProvider = .dorm
        ownership = CampusAutomationOwnershipSnapshot(
            currentOwner: CampusAutomationHost(
                hostID: "com.local.CodexQuotaBar",
                displayName: "我的 Mac 管家",
                bundleID: "com.local.CodexQuotaBar"
            ),
            ownerRunning: true,
            canTransfer: true,
            isCurrentHostOwner: true
        )
        dormAccount = "已配置宿舍区账号"
        recentOperations = [
            CampusRecentOperation(
                title: "等待可用校园网",
                detail: "当前没有检测到可登录的校园网环境。",
                tone: .caution,
                date: Date()
            ),
        ]
    }

    static func visualReference() -> SZUNETManagementModel {
        SZUNETManagementModel(visualReference: true)
    }

    var showsVisualDeviceLimitConfirmation: Bool {
        isVisualReference && forceLoginProvider != nil
    }

    var statusTone: CampusVisualTone {
        guard let result else { return .neutral }
        if visibleErrorCode != nil || result.outcome == .failed || result.outcome == .blocked {
            return .caution
        }
        switch result.sessionState {
        case .online: return .positive
        case .offline: return .caution
        case .blocked: return .critical
        case .unknown: return .neutral
        }
    }

    var headerBadgeText: String {
        if isWorking { return "检测中" }
        return switch result?.sessionState {
        case .online: "已连接"
        case .blocked: "连接受阻"
        case .offline, .unknown, nil: "未连接"
        }
    }

    var headerBadgeIcon: String {
        result?.sessionState == .online ? "wifi" : "wifi.slash"
    }

    var currentStatusTitle: String {
        if isWorking { return "正在检查校园网状态" }
        if let code = visibleErrorCode { return friendlyErrorTitle(code) }
        return switch result?.sessionState {
        case .online: "校园网已连接"
        case .offline: "当前未连接校园网"
        case .blocked: "校园网操作已安全阻止"
        case .unknown, nil: "等待检测校园网状态"
        }
    }

    var currentStatusDetail: String {
        if let code = visibleErrorCode { return friendlyErrorDetail(code) }
        return switch result?.sessionState {
        case .online: "当前会话已通过 Provider 验证，可以正常使用。"
        case .offline:
            switch result?.networkContext {
            case .dorm: "已检测到宿舍区网络，可以执行登录。"
            case .teaching: "已检测到教学区网络，可以执行登录。"
            default: "当前没有检测到可登录的校园网环境。"
            }
        case .blocked: "安全门控阻止了本次操作，请根据技术代码检查设置。"
        case .unknown, nil: "刷新状态后显示网络区域与会话结果。"
        }
    }

    var technicalCode: String? { visibleErrorCode }

    var guidanceTitle: String {
        visibleErrorCode == nil ? "如何保持稳定？" : "如何解决？"
    }

    var guidanceSteps: [String] {
        if visibleErrorCode != nil {
            return ["确认校园网模块已经启用", "检查账号、Provider 与凭据设置", "刷新脱敏诊断并查看技术代码"]
        }
        return ["保持正确的宿舍区或教学区网络", "按需开启自动登录和连通性监测", "异常时先刷新状态再查看诊断"]
    }

    var networkRegionText: String {
        return switch result?.networkContext {
        case .dorm: "宿舍区"
        case .teaching: "教学区"
        case .otherCampus: "其他校园区域"
        case .nonCampus: "非校园网"
        case .ambiguous: "环境冲突"
        case .unknown, nil: "未选择"
        }
    }

    var sessionText: String {
        return switch result?.sessionState {
        case .online: "已登录"
        case .offline: "未登录"
        case .blocked: "已阻止"
        case .unknown, nil: "未知"
        }
    }

    var onlineDeviceText: String {
        guard let count = result?.onlineDeviceCount else { return "待确认" }
        return "\(count)/\(result?.onlineDeviceLimit ?? 3)"
    }

    var automaticEnabled: Bool { result?.automaticEnabled ?? false }
    var hasAutomationState: Bool { result?.automaticEnabled != nil }
    var automaticText: String {
        guard hasAutomationState else { return "未知" }
        return automaticEnabled ? "已开启" : "已关闭"
    }
    var autoLoginDetail: String {
        automaticEnabled ? "网络恢复后由当前所有者尝试自动登录" : "已暂停后台自动登录"
    }

    var networkProbeEnabled: Bool { result?.networkProbeEnabled ?? false }
    var hasProbeState: Bool { result?.networkProbeEnabled != nil }
    var probeInterval: SZUNETProbeInterval {
        SZUNETProbeInterval(rawValue: result?.probeIntervalSeconds ?? 60) ?? .oneMinute
    }

    var lastCheckedText: String {
        guard let date = result?.observedAt else { return "—" }
        return Self.timeFormatter.string(from: date)
    }

    var accountSummary: String {
        let enabledCount = [dormEnabled, teachingEnabled].filter { $0 }.count
        return enabledCount == 0 ? "尚未启用 Provider" : "已启用 \(enabledCount) 个 Provider"
    }

    var ownershipText: String {
        "所有者：\(ownership?.currentOwner?.displayName ?? "无")"
    }
    var isCurrentOwner: Bool { ownership?.isCurrentHostOwner ?? false }
    var canTakeOwnership: Bool { ownership?.canTransfer ?? false }
    var ownershipWarning: String? {
        guard let owner = ownership?.currentOwner, !owner.supportsOwnershipProtocol else { return nil }
        return "OWNERSHIP_UPGRADE_REQUIRED: \(owner.displayName)"
    }

    var credentialDisclosure: String { credentialDisclosureText }

    func load() async {
        guard !isVisualReference, let runtime else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            providerConfiguration = try await runtime.providerConfiguration()
            apply(providerConfiguration)
            ownership = try await runtime.ownershipSnapshot()
            let loaded = try await runtime.execute(
                .status,
                provider: .auto,
                interactive: false,
                timeoutSeconds: 10
            )
            result = loaded
            message = nil
            record(command: .status, result: loaded)
        } catch {
            message = String(describing: error)
            recordFailure(title: "状态刷新失败", detail: "内置 Runtime 暂时无法读取状态。")
        }
    }

    func run(_ command: SZUNETCommand, provider: SZUNETCommandProvider = .auto) {
        guard !isWorking else { return }
        if isVisualReference {
            applyVisualCommand(command, provider: provider)
            return
        }
        guard let runtime else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let completed = try await runtime.execute(
                    command,
                    provider: provider,
                    interactive: true,
                    timeoutSeconds: 30
                )
                result = completed
                message = completed.errorCode ?? completed.outcome.rawValue
                record(command: command, result: completed)
                ownership = try? await runtime.ownershipSnapshot()
                if command == .login,
                   provider != .teaching,
                   completed.outcome == .blocked,
                   completed.errorCode == "AUTH_DEVICE_LIMIT" {
                    forceLoginProvider = provider
                }
            } catch {
                message = String(describing: error)
                recordFailure(title: command.failureTitle, detail: "操作未完成，请刷新诊断后重试。")
            }
        }
    }

    /// Consumes the pending warning before dispatching the one-shot force
    /// command. A second confirmation tap therefore cannot issue another
    /// request while the first operation is running.
    func confirmForceLogin() {
        guard let provider = forceLoginProvider else { return }
        forceLoginProvider = nil
        run(.forceLogin, provider: provider)
    }

    func cancelForceLogin() {
        forceLoginProvider = nil
    }

    func setProbeInterval(_ interval: SZUNETProbeInterval) {
        let command: SZUNETCommand = switch interval {
        case .thirtySeconds: .probeEvery30Seconds
        case .oneMinute: .probeEvery60Seconds
        case .twoMinutes: .probeEvery120Seconds
        case .fiveMinutes: .probeEvery300Seconds
        }
        run(command)
    }

    func saveProviders() async {
        guard !isWorking else { return }
        if isVisualReference {
            recordSuccess(title: "Provider 设置已保存", detail: "视觉预览没有写入真实配置或钥匙串。")
            dormPassword = ""
            teachingPassword = ""
            return
        }
        guard let runtime else { return }
        isWorking = true
        defer { isWorking = false }
        var updated = providerConfiguration
        updated.dorm.enabled = dormEnabled
        updated.dorm.accountLabel = dormAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.teaching.enabled = teachingEnabled
        updated.teaching.accountLabel = teachingAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await runtime.updateProviderConfiguration(updated)
            if !dormPassword.isEmpty {
                try await runtime.savePassword(dormPassword, provider: .dorm)
            }
            if !teachingPassword.isEmpty {
                try await runtime.savePassword(teachingPassword, provider: .teaching)
            }
            dormPassword = ""
            teachingPassword = ""
            providerConfiguration = updated
            message = "Provider 设置已保存。"
            recordSuccess(title: "Provider 设置已保存", detail: "账号和启用状态已经更新。")
        } catch {
            message = String(describing: error)
            recordFailure(title: "保存设置失败", detail: "配置或钥匙串没有完成更新。")
        }
    }

    func takeOwnership() async {
        await ownershipOperation(title: "自动化所有权已转移") {
            guard let runtime = self.runtime else { throw SZUNETEmbeddedError.invalidProviderConfiguration }
            return try await runtime.takeAutomationOwnership()
        }
    }

    func releaseOwnership() async {
        await ownershipOperation(title: "自动化所有权已释放") {
            guard let runtime = self.runtime else { throw SZUNETEmbeddedError.invalidProviderConfiguration }
            return try await runtime.releaseAutomationOwnership()
        }
    }

    private func ownershipOperation(
        title: String,
        _ operation: () async throws -> CampusAutomationOwnershipSnapshot
    ) async {
        guard !isWorking else { return }
        if isVisualReference {
            if isCurrentOwner {
                ownership = CampusAutomationOwnershipSnapshot(
                    currentOwner: nil,
                    ownerRunning: false,
                    canTransfer: true,
                    isCurrentHostOwner: false
                )
            } else {
                ownership = CampusAutomationOwnershipSnapshot(
                    currentOwner: CampusAutomationHost(
                        hostID: "com.local.CodexQuotaBar",
                        displayName: "我的 Mac 管家",
                        bundleID: "com.local.CodexQuotaBar"
                    ),
                    ownerRunning: true,
                    canTransfer: true,
                    isCurrentHostOwner: true
                )
            }
            recordSuccess(title: title, detail: ownershipText)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            ownership = try await operation()
            message = nil
            recordSuccess(title: title, detail: ownershipText)
        } catch {
            message = String(describing: error)
            recordFailure(title: "所有权操作失败", detail: "当前所有者未发生变化。")
        }
    }

    private func apply(_ value: CampusProductConfiguration) {
        dormEnabled = value.dorm.enabled
        dormAccount = value.dorm.accountLabel
        teachingEnabled = value.teaching.enabled
        teachingAccount = value.teaching.accountLabel
    }

    private func applyVisualCommand(_ command: SZUNETCommand, provider: SZUNETCommandProvider) {
        let now = Date()
        switch command {
        case .login:
            result = SZUNETCommandResult(
                requestId: UUID().uuidString,
                outcome: .succeeded,
                provider: provider.resultProvider,
                networkContext: provider == .teaching ? .teaching : .dorm,
                sessionState: .online,
                automaticEnabled: automaticEnabled,
                ownerAppRunning: true,
                networkProbeEnabled: networkProbeEnabled,
                probeIntervalSeconds: probeInterval.rawValue,
                observedAt: now
            )
        case .forceLogin:
            result = resultReplacing(
                session: .online,
                observedAt: now
            )
        case .logout:
            result = resultReplacing(session: .offline, observedAt: now)
        case .pause:
            result = resultReplacing(automaticEnabled: false, observedAt: now)
        case .resume:
            result = resultReplacing(automaticEnabled: true, observedAt: now)
        case .enableProbe:
            result = resultReplacing(networkProbeEnabled: true, observedAt: now)
        case .disableProbe:
            result = resultReplacing(networkProbeEnabled: false, observedAt: now)
        case .probeEvery30Seconds:
            result = resultReplacing(interval: 30, observedAt: now)
        case .probeEvery60Seconds:
            result = resultReplacing(interval: 60, observedAt: now)
        case .probeEvery120Seconds:
            result = resultReplacing(interval: 120, observedAt: now)
        case .probeEvery300Seconds:
            result = resultReplacing(interval: 300, observedAt: now)
        case .status, .check, .diagnostics, .openSettings:
            result = resultReplacing(observedAt: now)
        }
        if let result { record(command: command, result: result) }
    }

    private func resultReplacing(
        session: SZUNETSessionState? = nil,
        automaticEnabled: Bool? = nil,
        networkProbeEnabled: Bool? = nil,
        interval: Int? = nil,
        observedAt: Date
    ) -> SZUNETCommandResult {
        let current = result
        return SZUNETCommandResult(
            requestId: UUID().uuidString,
            outcome: .succeeded,
            provider: current?.provider ?? .auto,
            networkContext: current?.networkContext ?? .unknown,
            sessionState: session ?? current?.sessionState ?? .unknown,
            automaticEnabled: automaticEnabled ?? current?.automaticEnabled,
            ownerAppRunning: current?.ownerAppRunning,
            networkProbeEnabled: networkProbeEnabled ?? current?.networkProbeEnabled,
            probeIntervalSeconds: interval ?? current?.probeIntervalSeconds,
            observedAt: observedAt
        )
    }

    private func record(command: SZUNETCommand, result: SZUNETCommandResult) {
        let code = visibleErrorCode(for: result)
        let succeeded = code == nil && result.isSuccess
        let title = succeeded ? command.successTitle : command.failureTitle
        let detail = code.map(friendlyErrorDetail) ?? command.successDetail(for: result)
        let tone: CampusVisualTone = succeeded ? .positive : .caution
        prepend(CampusRecentOperation(title: title, detail: detail, tone: tone, date: Date()))
    }

    private func recordSuccess(title: String, detail: String) {
        prepend(CampusRecentOperation(title: title, detail: detail, tone: .positive, date: Date()))
    }

    private func recordFailure(title: String, detail: String) {
        prepend(CampusRecentOperation(title: title, detail: detail, tone: .caution, date: Date()))
    }

    private func prepend(_ operation: CampusRecentOperation) {
        recentOperations.insert(operation, at: 0)
        if recentOperations.count > 4 {
            recentOperations.removeLast(recentOperations.count - 4)
        }
    }

    private func friendlyErrorTitle(_ code: String) -> String {
        return switch code {
        case "CRED_MISSING", "CRED_MIGRATION_REQUIRED": "校园网凭据尚未配置"
        case "PROVIDER_DISABLED": "当前 Provider 未启用"
        case "ENV_NON_CAMPUS": "当前不是可识别的校园网"
        case "ENV_AMBIGUOUS": "校园网环境识别冲突"
        case "ENV_PORTAL_IDENTITY_UNVERIFIED": "校园网门户尚未确认"
        case "ENV_SOURCE_ROUTE_UNVERIFIED": "校园网源路由尚未确认"
        case "AUTH_BAD_PASSWORD": "校园网账号或密码错误"
        case "AUTH_DEVICE_LIMIT": "校园网设备数量已达上限"
        case "NET_CAMPUS_EGRESS_UNAVAILABLE": "校园网出口暂不可用"
        case "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED": "当前 Provider 不支持强制切换"
        case "AUTH_NOT_CONFIRMED": "登录结果尚未确认"
        case "SESSION_ONLINE": "退出尚未确认"
        case "SESSION_UNKNOWN": "校园网会话状态待确认"
        case "NET_TIMEOUT": "校园网服务响应超时"
        case "SRUN_LOGOUT_DISABLED": "Teaching 退出尚未开放"
        case "AUTOMATION_OWNER_CONFLICT": "自动化所有权已经变化"
        default: "校园网操作未完成"
        }
    }

    private func friendlyErrorDetail(_ code: String) -> String {
        return switch code {
        case "CRED_MISSING": "请在账号与维护中保存对应 Provider 的密码。"
        case "CRED_MIGRATION_REQUIRED": "请完成旧凭据迁移后再尝试登录。"
        case "PROVIDER_DISABLED": "请先在账号与维护中启用对应 Provider。"
        case "ENV_NON_CAMPUS": "切换到宿舍区或教学区校园网络后重新检查。"
        case "ENV_AMBIGUOUS": "当前网络证据相互冲突，模块已安全停止认证。"
        case "ENV_PORTAL_IDENTITY_UNVERIFIED": "未识别到受信任的校园网门户，本次认证没有继续。"
        case "ENV_SOURCE_ROUTE_UNVERIFIED": "未确认校园网源地址与路由，本次认证没有继续。"
        case "AUTH_BAD_PASSWORD": "请检查账号和密码，现有密码不会显示在界面中。"
        case "AUTH_DEVICE_LIMIT": "账号已有 3 台设备在线，普通登录已阻止以避免挤下其他设备。确认后可请求服务端切换一台旧设备。"
        case "NET_CAMPUS_EGRESS_UNAVAILABLE": "门户仍保留本机在线记录，但绑定校园源地址的直连外网检测失败；已避免无效重复登录。"
        case "AUTH_DEVICE_REPLACEMENT_UNSUPPORTED": "强制切换仅适用于宿舍区 Dorm；Teaching 不会发送此请求。"
        case "AUTH_NOT_CONFIRMED": "认证请求已返回，但门户尚未确认当前账号在线。"
        case "SESSION_ONLINE": "退出请求已发送，但门户仍报告当前账号在线。"
        case "SESSION_UNKNOWN": "门户暂时无法给出可靠会话状态，请稍后刷新。"
        case "NET_TIMEOUT": "校园网门户响应超时；若网络已变化，请刷新状态确认最终结果。"
        case "SRUN_LOGOUT_DISABLED": "未经现场验证，不会发送 Teaching 退出请求。"
        case "AUTOMATION_OWNER_CONFLICT": "另一客户端持有自动化；本次自动认证没有读取凭据。"
        default: "请刷新状态并查看脱敏诊断中的技术代码。"
        }
    }

    private var visibleErrorCode: String? {
        guard let result else { return nil }
        return visibleErrorCode(for: result)
    }

    private func visibleErrorCode(for result: SZUNETCommandResult) -> String? {
        guard let code = result.errorCode else { return nil }
        if result.isSuccess,
           code == "SESSION_ONLINE" || code == "SESSION_OFFLINE" {
            return nil
        }
        return code
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct CampusRecentOperation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let tone: CampusVisualTone
    let date: Date

    var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

enum CampusVisualTone {
    case neutral
    case positive
    case caution
    case critical

    var foreground: Color {
        switch self {
        case .neutral: .secondary
        case .positive: CampusTheme.success
        case .caution: CampusTheme.warning
        case .critical: CampusTheme.error
        }
    }

    var valueForeground: Color {
        self == .neutral ? .primary : foreground
    }

    var fill: Color {
        switch self {
        case .neutral: CampusTheme.inset
        case .positive: CampusTheme.success.opacity(0.12)
        case .caution: CampusTheme.warning.opacity(0.11)
        case .critical: CampusTheme.error.opacity(0.11)
        }
    }

    var largeSymbol: String {
        switch self {
        case .neutral: "questionmark.circle"
        case .positive: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var smallSymbol: String {
        switch self {
        case .neutral: "circle"
        case .positive: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

private enum CampusTheme {
    static let canvas = dynamic(light: 0xF7F8FA, dark: 0x0D0F13)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1F27)
    static let inset = dynamic(light: 0xF4F6FA, dark: 0x222834)
    static let border = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let shadow = dynamic(light: 0x1B2436, lightAlpha: 0.08, dark: 0x000000, darkAlpha: 0.42)
    static let accent = dynamic(light: 0x2476F2, dark: 0x64A0FF)
    static let success = dynamic(light: 0x20A53A, dark: 0x42D36C)
    static let warning = dynamic(light: 0xF08316, dark: 0xFFA340)
    static let error = dynamic(light: 0xD93D36, dark: 0xFF6B60)

    private static func dynamic(
        light: UInt32,
        lightAlpha: Double = 1,
        dark: UInt32,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

private struct CampusSectionHeader: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CampusTheme.accent)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CampusVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(CampusTheme.border)
            .frame(width: 1)
            .padding(.vertical, 1)
    }
}

private struct CampusSettingRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 11) {
            CampusIconTile(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            accessory
        }
        .padding(.vertical, 5)
    }
}

private struct CampusActionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                CampusIconTile(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct CampusIconTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(CampusTheme.accent)
            .frame(width: 34, height: 34)
            .background(CampusTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CampusStatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
    }
}

private struct CampusBoundaryRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CampusTheme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CampusTheme.border, lineWidth: 1)
        }
    }
}

private struct CampusFilledButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

private struct CampusOutlinedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(CampusTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(CampusTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

private struct CampusCompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(CampusTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(CampusTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

private extension View {
    func campusCard(minHeight: CGFloat) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(CampusTheme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(CampusTheme.border, lineWidth: 1)
            }
            .shadow(color: CampusTheme.shadow, radius: 8, y: 2)
    }
}

private extension SZUNETCommandProvider {
    var resultProvider: SZUNETResultProvider {
        switch self {
        case .auto: .auto
        case .dorm: .dorm
        case .teaching: .teaching
        }
    }
}

private extension SZUNETCommand {
    var successTitle: String {
        switch self {
        case .status: "状态已刷新"
        case .check: "网络检查已完成"
        case .login: "登录操作已完成"
        case .forceLogin: "强制切换已完成"
        case .logout: "退出操作已完成"
        case .pause: "自动登录已暂停"
        case .resume: "自动登录已开启"
        case .enableProbe: "连通性监测已开启"
        case .disableProbe: "连通性监测已关闭"
        case .probeEvery30Seconds, .probeEvery60Seconds, .probeEvery120Seconds, .probeEvery300Seconds:
            "检测间隔已更新"
        case .diagnostics: "脱敏诊断已刷新"
        case .openSettings: "设置已打开"
        }
    }

    var successDetail: String {
        switch self {
        case .status: "已读取最新校园网状态。"
        case .check: "网络区域与会话状态已经更新。"
        case .login: "请根据当前状态确认登录结果。"
        case .forceLogin: "服务端已选择一台旧设备下线，请刷新状态确认结果。"
        case .logout: "请根据当前状态确认退出结果。"
        case .pause, .resume: "自动化状态已经更新。"
        case .enableProbe, .disableProbe: "后台连通性监测状态已经更新。"
        case .probeEvery30Seconds, .probeEvery60Seconds, .probeEvery120Seconds, .probeEvery300Seconds:
            "新的检测周期已经保存。"
        case .diagnostics: "诊断内容保持脱敏，不包含账号或密码。"
        case .openSettings: "校园网设置入口已经打开。"
        }
    }

    func successDetail(for result: SZUNETCommandResult) -> String {
        switch (self, result.sessionState) {
        case (.login, .online): "校园网会话已确认在线。"
        case (.logout, .offline): "校园网会话已确认退出。"
        default: successDetail
        }
    }

    var failureTitle: String {
        switch self {
        case .login: "登录操作失败"
        case .forceLogin: "强制切换失败"
        case .logout: "退出操作失败"
        case .diagnostics: "诊断刷新失败"
        default: "校园网操作失败"
        }
    }
}
