/// Injected sleeping so supervisors and backoff are testable with a fake.
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Real sleeper backed by the continuous clock.
public struct ContinuousClockSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// Source of uniform randomness in [0, 1) for jitter. Injected so tests are deterministic.
public protocol RandomUnitSource: Sendable {
    func nextUnit() -> Double
}

/// System randomness (not security-sensitive: used only for backoff jitter).
public struct SystemRandomUnitSource: RandomUnitSource {
    public init() {}
    public func nextUnit() -> Double {
        var generator = SystemRandomNumberGenerator()
        return Double.random(in: 0..<1, using: &generator)
    }
}
