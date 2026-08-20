/// Jittered exponential backoff. Pure: same inputs, same output.
public struct BackoffPolicy: Sendable, Equatable {
    public let initial: Duration
    public let multiplier: Double
    public let cap: Duration
    /// Fraction of the computed delay that jitter may add or remove (0 = none, 0.5 = ±50%).
    public let jitter: Double

    public init(initial: Duration, multiplier: Double, cap: Duration, jitter: Double) {
        self.initial = initial
        self.multiplier = multiplier
        self.cap = cap
        self.jitter = min(max(jitter, 0), 1)
    }

    /// 500 ms, doubling, capped at 30 s, ±25% jitter. Unbounded attempts: a walkie-talkie never gives up.
    public static let `default` = BackoffPolicy(
        initial: .milliseconds(500), multiplier: 2, cap: .seconds(30), jitter: 0.25
    )

    /// Delay before retry number `attempt` (1-based). `unitRandom` in [0, 1) supplies the jitter.
    public func delay(forAttempt attempt: Int, unitRandom: Double) -> Duration {
        let exponent = Double(max(attempt, 1) - 1)
        let base = min(seconds(initial) * pow(multiplier, exponent), seconds(cap))
        let spread = base * jitter
        let jittered = base - spread + (2 * spread * min(max(unitRandom, 0), 1))
        return .seconds(max(jittered, 0))
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private func pow(_ base: Double, _ exponent: Double) -> Double {
    // Integer exponent path avoids importing Foundation's pow; exponents here are small attempt counts.
    var result = 1.0
    var count = Int(exponent)
    while count > 0 {
        result *= base
        count -= 1
    }
    return result
}
