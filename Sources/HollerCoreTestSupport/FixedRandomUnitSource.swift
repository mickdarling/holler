public import HollerCore

/// Deterministic jitter source.
public struct FixedRandomUnitSource: RandomUnitSource {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public func nextUnit() -> Double { value }
}
