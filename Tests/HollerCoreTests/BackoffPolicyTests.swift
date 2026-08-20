import Testing
@testable import HollerCore

@Suite("BackoffPolicy")
struct BackoffPolicyTests {
    let policy = BackoffPolicy(initial: .seconds(1), multiplier: 2, cap: .seconds(8), jitter: 0.5)

    @Test("doubles per attempt with mid jitter", arguments: [(1, 1.0), (2, 2.0), (3, 4.0), (4, 8.0)])
    func doubling(attempt: Int, expectedSeconds: Double) {
        let delay = policy.delay(forAttempt: attempt, unitRandom: 0.5)
        #expect(delay == .seconds(expectedSeconds))
    }

    @Test("caps at the configured maximum")
    func cap() {
        #expect(policy.delay(forAttempt: 20, unitRandom: 0.5) == .seconds(8))
    }

    @Test("jitter spreads symmetrically around the base")
    func jitterRange() {
        #expect(policy.delay(forAttempt: 2, unitRandom: 0.0) == .seconds(1))
        #expect(policy.delay(forAttempt: 2, unitRandom: 1.0) == .seconds(3))
    }

    @Test("attempt below 1 is treated as 1")
    func floorAttempt() {
        #expect(policy.delay(forAttempt: 0, unitRandom: 0.5) == .seconds(1))
    }

    @Test("default policy starts at 500ms and caps at 30s")
    func defaults() {
        #expect(BackoffPolicy.default.delay(forAttempt: 1, unitRandom: 0.5) == .milliseconds(500))
        #expect(BackoffPolicy.default.delay(forAttempt: 50, unitRandom: 0.5) == .seconds(30))
    }
}
