public import Foundation
import Synchronization

/// Fan-out for values to any number of AsyncStream subscribers (AsyncStream itself is single-consumer).
/// Late subscribers receive only future values. Lock-protected; publishing needs no actor hop.
public final class Broadcaster<Element: Sendable>: Sendable {
    public typealias Continuation = AsyncStream<Element>.Continuation
    private let continuations = Mutex<[UUID: Continuation]>([:])
    private let bufferingPolicy: Continuation.BufferingPolicy

    public init(bufferingPolicy: Continuation.BufferingPolicy = .bufferingNewest(16)) {
        self.bufferingPolicy = bufferingPolicy
    }

    public func subscribe() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    public func send(_ value: Element) {
        let targets = continuations.withLock { Array($0.values) }
        targets.forEach { $0.yield(value) }
    }

    public func finish() {
        let targets = continuations.withLock { store -> [Continuation] in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        targets.forEach { $0.finish() }
    }

    public var subscriberCount: Int { continuations.withLock { $0.count } }

    private func remove(_ id: UUID) {
        continuations.withLock { _ = $0.removeValue(forKey: id) }
    }
}
