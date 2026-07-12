import Foundation

enum PortalResponseClassifier {
    static func success(_ parsedOrText: Any) -> Bool? {
        if let dictionary = parsedOrText as? [String: Any] {
            var values: [String: Any] = [:]
            dictionary.forEach { values[$0.key.lowercased()] = $0.value }
            let message = values.values.map { String(describing: $0) }.joined(separator: " ")
            if containsPasswordError(message) { return false }
            if containsExistingSessionSuccess(message) { return true }
            for key in ["success", "result", "ret_code", "code"] {
                if let result = PortalCodec.boolean(values[key]) { return result }
            }
            if containsFailure(message) { return false }
            if containsSuccess(message) { return true }
            return nil
        }
        let text = String(describing: parsedOrText)
        if containsFailure(text) { return false }
        if containsSuccess(text) { return true }
        return nil
    }

    static func inactiveLogout(_ parsedOrText: Any) -> Bool {
        if let dictionary = parsedOrText as? [String: Any] {
            var values: [String: Any] = [:]
            dictionary.forEach { values[$0.key.lowercased()] = $0.value }
            let message = values.values.map { String(describing: $0) }.joined(separator: " ")
            let result = values["result"] ?? values["ret_code"] ?? values["code"]
            return PortalCodec.boolean(result) != true && containsInactiveLogoutMessage(message)
        }
        return containsInactiveLogoutMessage(String(describing: parsedOrText))
    }

    static func responseText(_ parsedOrText: Any) -> String {
        if let dictionary = parsedOrText as? [String: Any] {
            return dictionary.values.map { String(describing: $0) }.joined(separator: " ")
        }
        return String(describing: parsedOrText)
    }

    static func containsPasswordError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let password = ["password", "passwd", "密码", "口令"].contains { lowered.contains($0) }
        let error = ["wrong", "incorrect", "invalid", "error", "错误", "不正确", "不匹配", "失败"]
            .contains { lowered.contains($0) }
        return password && error
    }

    private static func containsSuccess(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "success", "login_ok", "logout_ok", "认证成功", "登录成功", "登陆成功",
            "注销成功", "下线成功", "退出成功", "已经在线", "已在线", "已登录", "已登陆",
            "logged in", "online",
        ].contains { lowered.contains($0) }
    }

    private static func containsExistingSessionSuccess(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["已经在线", "已在线", "already online", "already logged in"]
            .contains { lowered.contains($0) }
    }

    private static func containsFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "fail", "failed", "error", "认证失败", "登录失败", "登陆失败", "注销失败",
            "下线失败", "不在线", "not online", "not logged in", "页面已过期", "欠费",
            "不存在", "错误",
        ].contains { lowered.contains($0) }
    }

    private static func containsInactiveLogoutMessage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "不在线", "未在线", "未登录", "未登陆", "没有登录", "没有登陆", "no active",
            "no session", "not online", "not logged in", "already logged out",
        ].contains { lowered.contains($0) }
    }
}
