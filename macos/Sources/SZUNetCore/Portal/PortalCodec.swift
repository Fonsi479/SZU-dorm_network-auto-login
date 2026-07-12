import Foundation

enum PortalCodec {
    static func parseJSONP(_ text: String) -> Any {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[\w.$]+\(([\s\S]*)\)\s*;?$"#
        let payload: String
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
               in: stripped,
               range: NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
           ),
           let range = Range(match.range(at: 1), in: stripped) {
            payload = String(stripped[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            payload = stripped
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return stripped
        }
        return object
    }

    static func dictionary(_ parsed: Any) -> [String: Any]? {
        parsed as? [String: Any]
    }

    static func string(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "<null>" { return text }
        }
        return ""
    }

    static func integer(_ value: Any?, default fallback: Int = 0) -> Int {
        guard let value else { return fallback }
        if let number = value as? NSNumber { return number.intValue }
        return Int(String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.intValue != 0 }
        let normalized = String(describing: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["1", "true", "ok", "success", "online"].contains(normalized) { return true }
        if [
            "0", "false", "fail", "failed", "error", "-1", "offline", "inactive",
            "not_online", "not online", "not_logged_in", "not logged in",
            "already_logged_out", "already logged out",
        ].contains(normalized) { return false }
        return nil
    }

    static func pageVariables(_ text: String) -> [String: String] {
        let pattern = #"\b(v46ip|ss5|v4ip|ss3|ss4|olmac|vlanid)\s*=\s*('[^']*'|\"[^\"]*\"|[^;,\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var values: [String: String] = [:]
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            var value = String(text[valueRange]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.first == "'" || value.first == "\""),
               value.last == value.first {
                value = String(value.dropFirst().dropLast())
            }
            values[String(text[nameRange])] = value
        }
        return values
    }

    static func declaredLogoutURL(pageURL: URL?, pageText: String) -> URL? {
        func value(_ name: String) -> String {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name)
                + #"\s*=\s*('[^']*'|\"[^\"]*\"|[^;,\s]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: pageText,
                      range: NSRange(pageText.startIndex..<pageText.endIndex, in: pageText)
                  ),
                  let range = Range(match.range(at: 1), in: pageText) else { return "" }
            return String(pageText[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }

        guard let pageURL,
              !value("authlogoutpath").isEmpty,
              var base = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        if let port = Int(value("authlogoutport")), port > 0 { base.port = port }
        let host = value("authlogoutIP")
        if !host.isEmpty { base.host = host }
        guard let absolute = URL(string: value("authlogoutpath"), relativeTo: base.url)?.absoluteURL,
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else { return nil }
        let extra = value("authlogoutparam")
        if !extra.isEmpty {
            components.queryItems = (components.queryItems ?? [])
                + (URLComponents(string: "?" + extra)?.queryItems ?? [])
        }
        return components.url
    }

    static func normalizedMAC(_ value: String) -> String {
        let normalized = value.filter { $0.isHexDigit }.lowercased()
        return normalized.count == 12 ? normalized : ""
    }

    static func nonSentinelMAC(_ value: String) -> String {
        let normalized = normalizedMAC(value)
        guard normalized != "000000000000", normalized != "111111111111" else { return "" }
        return normalized
    }

    static func hexIPToDotted(_ value: String) -> String {
        let normalized = value.filter(\.isHexDigit)
        guard normalized.count == 8 else { return "" }
        var octets: [String] = []
        var index = normalized.startIndex
        for _ in 0..<4 {
            let end = normalized.index(index, offsetBy: 2)
            guard let octet = UInt8(normalized[index..<end], radix: 16) else { return "" }
            octets.append(String(octet))
            index = end
        }
        return octets.joined(separator: ".")
    }
}
