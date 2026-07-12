import Foundation

enum LegacyYAMLValue {
    case scalar(String)
    case list([String])
}

enum LegacyYAMLDocumentParser {
    typealias Document = [String: [String: LegacyYAMLValue]]

    static func parse(_ text: String) throws -> Document {
        var document: Document = [:]
        var section = ""
        var activeListKey: String?

        for (offset, rawLine) in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine))
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if line.prefix(while: { $0 == "\t" || $0 == " " }).contains("\t") {
                throw SZUNetError.configuration(
                    "旧 config.yaml 第 \(lineNumber) 行不能使用 Tab 缩进。"
                )
            }

            let indent = line.prefix { $0 == " " }.count
            let content = line.trimmingCharacters(in: .whitespaces)

            if indent == 0 {
                guard content.hasSuffix(":"), !content.hasPrefix("-") else {
                    throw SZUNetError.configuration(
                        "旧 config.yaml 第 \(lineNumber) 行格式不正确。"
                    )
                }
                section = String(content.dropLast()).trimmingCharacters(in: .whitespaces)
                document[section, default: [:]] = document[section, default: [:]]
                activeListKey = nil
                continue
            }

            guard !section.isEmpty else {
                throw SZUNetError.configuration(
                    "旧 config.yaml 第 \(lineNumber) 行缺少顶层配置段。"
                )
            }

            if indent >= 4, content.hasPrefix("- "), let key = activeListKey {
                let item = parseScalar(String(content.dropFirst(2)))
                var values: [String]
                if case .list(let existing)? = document[section]?[key] {
                    values = existing
                } else {
                    values = []
                }
                values.append(item)
                document[section]?[key] = .list(values)
                continue
            }

            guard indent == 2, let colon = mappingColon(in: content) else {
                throw SZUNetError.configuration(
                    "旧 config.yaml 第 \(lineNumber) 行格式不正确。"
                )
            }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let valueStart = content.index(after: colon)
            let rawValue = String(content[valueStart...]).trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                document[section]?[key] = .list([])
                activeListKey = key
            } else {
                document[section]?[key] = .scalar(parseScalar(rawValue))
                activeListKey = nil
            }
        }
        return document
    }

    private static func mappingColon(in value: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let activeQuote = quote {
                if activeQuote == "\"", character == "\\", !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == ":" {
                return index
            }
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let activeQuote = quote {
                if activeQuote == "\"", character == "\\", !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "#",
               index == value.startIndex || value[value.index(before: index)].isWhitespace {
                // Keep leading indentation intact. The caller needs it to
                // distinguish section keys from nested mappings.
                return String(value[..<index])
            }
        }
        return value
    }

    private static func parseScalar(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.first == "\"",
           value.last == "\"",
           let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(
               with: data,
               options: .fragmentsAllowed
           ) as? String {
            return decoded
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
