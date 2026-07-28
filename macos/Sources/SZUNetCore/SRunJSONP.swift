import Foundation

public struct SRunJSONPError: LocalizedError, Equatable {
    public let errorDescription: String?

    init(_ detail: String) {
        errorDescription = "SRUN_JSONP_MALFORMED: \(detail)"
    }
}

public enum SRunJSONP {
    public static let maximumBytes = 64 * 1_024

    public static func decode(_ data: Data, expectedCallback: String) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw SRunJSONPError("response_too_large") }
        guard expectedCallback.range(
            of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#,
            options: .regularExpression
        ) != nil else {
            throw SRunJSONPError("invalid_callback")
        }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            let encoding = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
            guard let decoded = String(data: data, encoding: encoding) else {
                throw SRunJSONPError("unsupported_encoding")
            }
            text = decoded
        }
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = expectedCallback + "("
        guard payload.hasPrefix(prefix) else { throw SRunJSONPError("callback_mismatch") }
        payload.removeFirst(prefix.count)
        if payload.hasSuffix(";") {
            payload.removeLast()
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard payload.hasSuffix(")") else { throw SRunJSONPError("trailing_content") }
        payload.removeLast()
        let jsonText = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard jsonText.hasPrefix("{"), jsonText.hasSuffix("}") else {
            throw SRunJSONPError("object_required")
        }
        guard let jsonData = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dictionary = object as? [String: Any] else {
            throw SRunJSONPError("invalid_json_object")
        }
        return dictionary
    }
}
