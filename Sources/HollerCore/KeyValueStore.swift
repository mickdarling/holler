public import Foundation

/// Minimal persistence seam so identity/preferences are testable without UserDefaults.
public protocol KeyValueStoring: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// UserDefaults-backed store. Resolves the suite on each call so no non-Sendable reference is retained.
public struct UserDefaultsKeyValueStore: KeyValueStoring {
    private let suiteName: String?
    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
}
