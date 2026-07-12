import Foundation

public struct AutoLoginBackoff: Equatable {
    public let intervals: [TimeInterval]
    public private(set) var failureIndex: Int
    public private(set) var nextAttempt: Date

    public init(
        intervals: [TimeInterval] = [120, 300, 600, 900],
        initialDelay: TimeInterval = 5,
        now: Date = Date()
    ) {
        precondition(!intervals.isEmpty)
        self.intervals = intervals
        self.failureIndex = 0
        self.nextAttempt = now.addingTimeInterval(initialDelay)
    }

    public var currentInterval: TimeInterval {
        intervals[failureIndex]
    }

    public func isDue(at date: Date = Date()) -> Bool {
        date >= nextAttempt
    }

    public mutating func consumeIfDue(at date: Date = Date()) -> Bool {
        guard isDue(at: date) else { return false }
        nextAttempt = date.addingTimeInterval(currentInterval)
        return true
    }

    public mutating func recordSuccess(at date: Date = Date()) {
        failureIndex = 0
        nextAttempt = date.addingTimeInterval(currentInterval)
    }

    public mutating func recordFailure(at date: Date = Date()) {
        failureIndex = min(failureIndex + 1, intervals.count - 1)
        nextAttempt = date.addingTimeInterval(currentInterval)
    }
}
