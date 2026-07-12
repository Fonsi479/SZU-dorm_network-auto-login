import SZUNetCore

struct AppStatusPresentation: Equatable {
    var text: String
    var tone: AppModel.StatusTone
    var detail: String
    var logMessage: String

    static func make(
        status: NetworkStatus,
        environment: NetworkEnvironment,
        autoLoginEnabled: Bool
    ) -> AppStatusPresentation {
        let text: String
        let tone: AppModel.StatusTone
        if !status.gatewayReachable {
            text = "●  校园网未连接"
            tone = .failure
        } else {
            switch status.campusSessionState {
            case .online:
                text = "●  校园网在线"
                tone = status.campusInternetOK ? .success : .warning
            case .offline:
                text = autoLoginEnabled
                    ? "●  校园网离线"
                    : "●  已退出校园网"
                tone = autoLoginEnabled ? .warning : .success
            case .unknown:
                text = "●  校园网状态待确认"
                tone = .warning
            }
        }

        let gateway = status.gatewayReachable ? "网关可达" : "网关不可达"
        let session: String
        switch status.campusSessionState {
        case .online: session = "门户会话在线"
        case .offline: session = "门户会话离线"
        case .unknown: session = "门户会话未知"
        }
        let internet = status.campusInternetOK ? "外网探测可达" : "外网探测不可达"
        let source = status.sourceIP.isEmpty ? "-" : status.sourceIP
        let detail: String
        if !status.gatewayReachable {
            detail = "\(environment.label)  ·  \(gateway)  ·  IP \(source)"
        } else {
            let internetSummary = status.campusInternetOK ? "外网可用" : "外网不可用"
            detail = "\(environment.label)  ·  \(internetSummary)  ·  IP \(source)"
        }

        return AppStatusPresentation(
            text: text,
            tone: tone,
            detail: detail,
            logMessage: "状态刷新：\(environment.label)，\(gateway)，\(session)，\(internet)，source_ip=\(source)"
        )
    }
}
