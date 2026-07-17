import Foundation
import Testing
@testable import SZUNetCore

@Suite("Automatic login backoff")
struct AutoLoginBackoffTests {
    @Test("a confirmed disconnect opens one immediate attempt")
    func disconnectOpensOneAttempt() {
        let now = Date(timeIntervalSince1970: 1_000)
        var backoff = AutoLoginBackoff(
            intervals: [120, 300],
            initialDelay: 5,
            now: now
        )

        backoff.recordSuccess(at: now)
        let attemptedWhileOnline = backoff.consumeIfDue(at: now.addingTimeInterval(30))
        #expect(!attemptedWhileOnline)

        let disconnectedAt = now.addingTimeInterval(30)
        backoff.allowImmediateAttempt(at: disconnectedAt)
        let immediateAttempt = backoff.consumeIfDue(at: disconnectedAt)
        let duplicateAttempt = backoff.consumeIfDue(at: disconnectedAt)
        #expect(immediateAttempt)
        #expect(!duplicateAttempt)
    }

    @Test("a failed immediate attempt returns to increasing backoff")
    func failedImmediateAttemptBacksOff() {
        let now = Date(timeIntervalSince1970: 2_000)
        var backoff = AutoLoginBackoff(
            intervals: [120, 300],
            initialDelay: 5,
            now: now
        )

        backoff.allowImmediateAttempt(at: now)
        let immediateAttempt = backoff.consumeIfDue(at: now)
        #expect(immediateAttempt)
        backoff.recordFailure(at: now)

        #expect(backoff.failureIndex == 1)
        let attemptedTooSoon = backoff.consumeIfDue(at: now.addingTimeInterval(299))
        let retryAttempt = backoff.consumeIfDue(at: now.addingTimeInterval(300))
        #expect(!attemptedTooSoon)
        #expect(retryAttempt)
    }
}
