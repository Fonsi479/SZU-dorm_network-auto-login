import CryptoKit
import Foundation

public struct SRunDerivedFields: Equatable, Sendable {
    public let infoJSON: String
    public let hmacMD5Hex: String
    public let passwordField: String
    public let infoField: String
    public let checksum: String
}

public enum SRunCrypto {
    public static let base64Alphabet = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"

    public static func deriveLoginFields(
        username: String,
        password: String,
        clientIP: String,
        acid: String,
        challenge: String,
        n: String = "200",
        type: String = "1"
    ) -> SRunDerivedFields {
        let hmac = hmacMD5Hex(password: password, challenge: challenge)
        let infoJSON = stableInfoJSON(
            username: username,
            password: password,
            clientIP: clientIP,
            acid: acid
        )
        let info = "{SRBX1}" + customBase64(xencode(message: infoJSON, key: challenge))
        let checksumInput = challenge + username
            + challenge + hmac
            + challenge + acid
            + challenge + clientIP
            + challenge + n
            + challenge + type
            + challenge + info
        return SRunDerivedFields(
            infoJSON: infoJSON,
            hmacMD5Hex: hmac,
            passwordField: "{MD5}" + hmac,
            infoField: info,
            checksum: sha1Hex(checksumInput)
        )
    }

    public static func stableInfoJSON(
        username: String,
        password: String,
        clientIP: String,
        acid: String
    ) -> String {
        "{\"username\":\(quoted(username)),\"password\":\(quoted(password)),"
            + "\"ip\":\(quoted(clientIP)),\"acid\":\(quoted(acid)),"
            + "\"enc_ver\":\"srun_bx1\"}"
    }

    public static func hmacMD5Hex(password: String, challenge: String) -> String {
        let key = SymmetricKey(data: Data(challenge.utf8))
        let code = HMAC<Insecure.MD5>.authenticationCode(
            for: Data(password.utf8),
            using: key
        )
        return hex(Data(code))
    }

    public static func sha1Hex(_ value: String) -> String {
        hex(Data(Insecure.SHA1.hash(data: Data(value.utf8))))
    }

    public static func xencode(message: String, key: String) -> Data {
        guard !message.isEmpty else { return Data() }
        var values = words(Data(message.utf8), includeLength: true)
        var keyWords = words(Data(key.utf8), includeLength: false)
        while keyWords.count < 4 { keyWords.append(0) }
        let last = values.count - 1
        var z = values[last]
        var sum: UInt32 = 0
        let delta: UInt32 = 0x9E37_79B9
        var rounds = 6 + 52 / values.count
        while rounds > 0 {
            sum &+= delta
            let e = Int((sum >> 2) & 3)
            for index in 0 ..< last {
                let y = values[index + 1]
                let mixed = mix(
                    z: z,
                    y: y,
                    sum: sum,
                    key: keyWords[(index & 3) ^ e]
                )
                values[index] &+= mixed
                z = values[index]
            }
            let y = values[0]
            let mixed = mix(
                z: z,
                y: y,
                sum: sum,
                key: keyWords[(last & 3) ^ e]
            )
            values[last] &+= mixed
            z = values[last]
            rounds -= 1
        }
        // The appended plaintext length word participates in encryption and is
        // ciphertext afterwards. Serialize every encrypted word; interpreting
        // the tail as a length truncates valid BX1 output.
        return bytes(values, includesLength: false)
    }

    private static func mix(z: UInt32, y: UInt32, sum: UInt32, key: UInt32) -> UInt32 {
        let first = (z >> 5) ^ (y << 2)
        let second = ((y >> 3) ^ (z << 4)) ^ (sum ^ y)
        return first &+ second &+ (key ^ z)
    }

    public static func customBase64(_ data: Data, alphabet: String = base64Alphabet) -> String {
        let table = Array(alphabet)
        precondition(table.count == 64)
        let bytes = Array(data)
        var output = ""
        var index = 0
        while index < bytes.count {
            let first = Int(bytes[index])
            let second = index + 1 < bytes.count ? Int(bytes[index + 1]) : 0
            let third = index + 2 < bytes.count ? Int(bytes[index + 2]) : 0
            output.append(table[first >> 2])
            output.append(table[((first & 3) << 4) | (second >> 4)])
            output.append(index + 1 < bytes.count ? table[((second & 15) << 2) | (third >> 6)] : "=")
            output.append(index + 2 < bytes.count ? table[third & 63] : "=")
            index += 3
        }
        return output
    }

    private static func quoted(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func words(_ data: Data, includeLength: Bool) -> [UInt32] {
        let bytes = Array(data)
        var result = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.enumerated() {
            result[index >> 2] |= UInt32(byte) << UInt32((index & 3) * 8)
        }
        if includeLength { result.append(UInt32(bytes.count)) }
        return result
    }

    private static func bytes(_ words: [UInt32], includesLength: Bool) -> Data {
        guard !words.isEmpty else { return Data() }
        let payloadWords = includesLength ? words.dropLast() : words[...]
        var result = Data()
        result.reserveCapacity(payloadWords.count * 4)
        for word in payloadWords {
            result.append(UInt8(truncatingIfNeeded: word))
            result.append(UInt8(truncatingIfNeeded: word >> 8))
            result.append(UInt8(truncatingIfNeeded: word >> 16))
            result.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        if includesLength, let requested = words.last {
            return Data(result.prefix(Int(requested)))
        }
        return result
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
