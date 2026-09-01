import CoreFoundation
import Foundation

/// Small, non-sensitive preferences shared by the independent SZUNET App and
/// its bundled JSON CLI. Credentials and Provider configuration never cross
/// this boundary.
public enum CampusAutomationPreferences {
    public static let ownerDefaultsDomain = "com.szu-netlogin.dorm-login"
    public static let networkProbeEnabledKey = "networkProbeEnabled"
    public static let probeIntervalSecondsKey = "networkProbeIntervalSeconds"
    public static let defaultProbeIntervalSeconds = 30
    public static let allowedProbeIntervals = [30, 60, 120, 300]

    public static func networkProbeEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: networkProbeEnabledKey) == nil
            ? true
            : defaults.bool(forKey: networkProbeEnabledKey)
    }

    public static func probeIntervalSeconds(in defaults: UserDefaults) -> Int {
        normalizedProbeInterval(defaults.integer(forKey: probeIntervalSecondsKey))
    }

    @discardableResult
    public static func setNetworkProbeEnabled(
        _ enabled: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        defaults.set(enabled, forKey: networkProbeEnabledKey)
        return enabled
    }

    @discardableResult
    public static func setProbeIntervalSeconds(
        _ seconds: Int,
        in defaults: UserDefaults
    ) -> Int {
        let normalized = normalizedProbeInterval(seconds)
        defaults.set(normalized, forKey: probeIntervalSecondsKey)
        return normalized
    }

    public static func normalizedProbeInterval(_ seconds: Int) -> Int {
        allowedProbeIntervals.contains(seconds) ? seconds : defaultProbeIntervalSeconds
    }

    public static func ownerNetworkProbeEnabled() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            networkProbeEnabledKey as CFString,
            ownerDefaultsDomain as CFString
        ) else { return true }
        return (value as? NSNumber)?.boolValue ?? true
    }

    public static func ownerProbeIntervalSeconds() -> Int {
        guard let value = CFPreferencesCopyAppValue(
            probeIntervalSecondsKey as CFString,
            ownerDefaultsDomain as CFString
        ) else { return defaultProbeIntervalSeconds }
        return normalizedProbeInterval((value as? NSNumber)?.intValue ?? 0)
    }

    @discardableResult
    public static func setOwnerNetworkProbeEnabled(_ enabled: Bool) -> Bool {
        CFPreferencesSetAppValue(
            networkProbeEnabledKey as CFString,
            enabled ? kCFBooleanTrue : kCFBooleanFalse,
            ownerDefaultsDomain as CFString
        )
        CFPreferencesAppSynchronize(ownerDefaultsDomain as CFString)
        return enabled
    }

    @discardableResult
    public static func setOwnerProbeIntervalSeconds(_ seconds: Int) -> Int {
        let normalized = normalizedProbeInterval(seconds)
        CFPreferencesSetAppValue(
            probeIntervalSecondsKey as CFString,
            NSNumber(value: normalized),
            ownerDefaultsDomain as CFString
        )
        CFPreferencesAppSynchronize(ownerDefaultsDomain as CFString)
        return normalized
    }
}
