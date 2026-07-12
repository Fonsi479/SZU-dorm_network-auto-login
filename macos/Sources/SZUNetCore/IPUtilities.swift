import Darwin
import Foundation

public enum IPv4CIDR {
    public static func isValid(_ cidr: String) -> Bool {
        contains(ip: "0.0.0.0", cidr: cidr) != nil
    }

    public static func contains(ip: String, cidr: String) -> Bool? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let ipValue = value(of: ip),
              let networkValue = value(of: String(parts[0])) else {
            return nil
        }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return (ipValue & mask) == (networkValue & mask)
    }

    public static func addressIsInAnyNetwork(_ address: String, networks: [String]) -> Bool {
        networks.contains { contains(ip: address, cidr: $0) == true }
    }

    public static func value(of address: String) -> UInt32? {
        var storage = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &storage) }) == 1 else {
            return nil
        }
        return UInt32(bigEndian: storage.s_addr)
    }

    public static func dottedAddress(fromHostOrder value: UInt32) -> String {
        [24, 16, 8, 0]
            .map { String((value >> UInt32($0)) & 0xFF) }
            .joined(separator: ".")
    }

    public static func portalInteger(_ address: String) -> String {
        guard let value = value(of: address) else { return "0" }
        return String(value)
    }

    public static func dottedAddress(fromLittleEndianPortalInteger value: Any?) -> String {
        guard let value,
              let number = UInt32(String(describing: value)) else {
            return ""
        }
        let reordered = number.byteSwapped
        return dottedAddress(fromHostOrder: reordered)
    }

    public static func normalized(_ address: String) -> String {
        guard let value = value(of: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }
        return dottedAddress(fromHostOrder: value)
    }
}
