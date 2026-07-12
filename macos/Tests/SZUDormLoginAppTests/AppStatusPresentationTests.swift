import Testing
import SZUNetCore
@testable import SZUDormLoginApp

@Suite("App session status presentation")
struct AppStatusPresentationTests {
    private let environment = NetworkEnvironment(
        label: "宿舍网络",
        isDormNetwork: true,
        autoLoginAvailable: true,
        sourceIP: "172.24.59.154"
    )

    @Test("default-route connectivity never masquerades as an online campus session")
    func internetProbeDoesNotOverrideOfflineSession() {
        let presentation = make(session: .offline, internetOK: true, autoLoginEnabled: true)

        #expect(presentation.text.contains("会话已离线"))
        #expect(!presentation.text.contains("会话已在线"))
        #expect(presentation.tone == .warning)
    }

    @Test("an unknown portal session remains unknown even when the internet probe works")
    func internetProbeDoesNotOverrideUnknownSession() {
        let presentation = make(session: .unknown, internetOK: true, autoLoginEnabled: true)

        #expect(presentation.text.contains("会话待确认"))
        #expect(presentation.detail.contains("门户会话未知"))
        #expect(presentation.tone == .warning)
    }

    @Test("a verified online portal session remains visible if an internet probe fails")
    func verifiedSessionOutranksInternetProbeFailure() {
        let presentation = make(session: .online, internetOK: false, autoLoginEnabled: true)

        #expect(presentation.text.contains("会话已在线"))
        #expect(presentation.detail.contains("外网探测不可达"))
        #expect(presentation.tone == .warning)
    }

    @Test("verified offline plus paused auto-login is presented as a completed logout")
    func pausedOfflineSessionIsLoggedOut() {
        let presentation = make(session: .offline, internetOK: false, autoLoginEnabled: false)

        #expect(presentation.text.contains("已退出校园网"))
        #expect(presentation.tone == .success)
    }

    private func make(
        session: CampusSessionState,
        internetOK: Bool,
        autoLoginEnabled: Bool
    ) -> AppStatusPresentation {
        AppStatusPresentation.make(
            status: NetworkStatus(
                gatewayReachable: true,
                campusInternetOK: internetOK,
                sourceIP: environment.sourceIP,
                campusSessionState: session
            ),
            environment: environment,
            autoLoginEnabled: autoLoginEnabled
        )
    }
}
