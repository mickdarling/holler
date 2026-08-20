public import HollerCore
import Synchronization

/// Dictionary-backed KeyValueStoring for tests.
public final class InMemoryKeyValueStore: KeyValueStoring, Sendable {
    private let storage = Mutex<[String: String]>([:])
    public init(_ initial: [String: String] = [:]) { storage.withLock { $0 = initial } }
    public func string(forKey key: String) -> String? { storage.withLock { $0[key] } }
    public func set(_ value: String?, forKey key: String) { storage.withLock { $0[key] = value } }
}
