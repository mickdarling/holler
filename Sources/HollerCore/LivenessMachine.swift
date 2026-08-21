/// Detects half-open sockets: ping on every tick, count unanswered pings, declare the connection dead after
/// `maxMissed` consecutive misses. Pure; the supervisor interprets the effects. Nonces are never reused within a
/// supervisor's lifetime (resets keep `nextNonce`) so a late pong from a previous socket cannot match a new ping.
public struct LivenessMachine: Sendable, Equatable {
    public struct State: Sendable, Equatable {
        public var nextNonce: UInt64
        public var pending: UInt64?
        public var missed: Int
        public init(nextNonce: UInt64 = 1, pending: UInt64? = nil, missed: Int = 0) {
            self.nextNonce = nextNonce
            self.pending = pending
            self.missed = missed
        }
    }

    public enum Event: Sendable, Equatable {
        case tick
        case pong(nonce: UInt64)
        case reset
    }

    public enum Effect: Sendable, Equatable {
        case sendPing(nonce: UInt64)
        case declareDead
    }

    public let maxMissed: Int

    public init(maxMissed: Int = 2) {
        self.maxMissed = max(maxMissed, 1)
    }

    public func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch event {
        case .tick:
            var next = state
            if next.pending != nil {
                next.missed += 1
                if next.missed >= maxMissed { return (State(nextNonce: next.nextNonce), [.declareDead]) }
            }
            let nonce = next.nextNonce
            next.pending = nonce
            next.nextNonce &+= 1
            return (next, [.sendPing(nonce: nonce)])
        case let .pong(nonce):
            guard nonce == state.pending else { return (state, []) }
            var next = state
            next.pending = nil
            next.missed = 0
            return (next, [])
        case .reset:
            return (State(nextNonce: state.nextNonce), [])
        }
    }
}
