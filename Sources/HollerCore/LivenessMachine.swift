/// Detects half-open sockets: ping on every tick, count intervals with no pong, declare the connection dead after
/// `maxMissed` consecutive silent intervals. Pure; the supervisor interprets the effects.
/// Nonces are monotonic for a supervisor's lifetime (resets keep `nextNonce`) so a late pong from a previous
/// socket cannot match a new ping. Several pings may be outstanding; a pong for any of them proves liveness.
public struct LivenessMachine: Sendable, Equatable {
    public struct State: Sendable, Equatable {
        public var nextNonce: UInt64
        /// Unanswered ping nonces for the current socket, oldest first; bounded to `maxMissed + 1`.
        public var outstanding: [UInt64]
        public var missed: Int
        public init(nextNonce: UInt64 = 1, outstanding: [UInt64] = [], missed: Int = 0) {
            self.nextNonce = nextNonce
            self.outstanding = outstanding
            self.missed = missed
        }
        /// The most recent unanswered ping, if any.
        public var pending: UInt64? { outstanding.last }
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
            if !next.outstanding.isEmpty {
                next.missed += 1
                if next.missed >= maxMissed { return (State(nextNonce: next.nextNonce), [.declareDead]) }
            }
            let nonce = next.nextNonce
            next.outstanding.append(nonce)
            if next.outstanding.count > maxMissed + 1 { next.outstanding.removeFirst() }
            next.nextNonce &+= 1
            return (next, [.sendPing(nonce: nonce)])
        case let .pong(nonce):
            guard let index = state.outstanding.firstIndex(of: nonce) else { return (state, []) }
            var next = state
            // This pong and every older outstanding ping are answered in spirit: the socket is alive.
            next.outstanding.removeSubrange(...index)
            next.missed = 0
            return (next, [])
        case .reset:
            return (State(nextNonce: state.nextNonce), [])
        }
    }
}
