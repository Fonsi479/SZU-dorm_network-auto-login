import Foundation

public struct PauseState: Codable, Equatable {
    public enum Mode: String, Codable {
        case manual
        case until
        case untilNextBoot
    }

    public var mode: Mode
    public var pausedAt: Date
    public var resumeAfter: Date?
    public var bootMarker: String?

    public init(
        mode: Mode,
        pausedAt: Date = Date(),
        resumeAfter: Date? = nil,
        bootMarker: String? = nil
    ) {
        self.mode = mode
        self.pausedAt = pausedAt
        self.resumeAfter = resumeAfter
        self.bootMarker = bootMarker
    }
}
