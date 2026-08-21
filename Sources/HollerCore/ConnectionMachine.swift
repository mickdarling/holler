/// Connection lifecycle as a pure state machine. The supervisor interprets effects; this type decides.
public struct ConnectionMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case connecting(attempt: Int)
        case connected
        case backingOff(attempt: Int)
        case stopped
    }

    public enum Event: Sendable, Equatable {
        case start
        case socketOpened
        case socketClosed(reason: String)
        case retryTimerFired
        case stop
    }

    public enum Effect: Sendable, Equatable {
        case openSocket
        case closeSocket
        case scheduleRetry(attempt: Int)
        case publish(HealthState)
    }

    public init() {}

    public func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch (state, event) {
        case (.idle, .start), (.stopped, .start):
            return (.connecting(attempt: 1), [.publish(.connecting(attempt: 1)), .openSocket])
        case (.connecting, .socketOpened), (.backingOff, .socketOpened):
            return (.connected, [.publish(.online)])
        case let (.connecting(attempt), .socketClosed), let (.backingOff(attempt), .socketClosed):
            return (.backingOff(attempt: attempt),
                    [.publish(.retrying(attempt: attempt)), .scheduleRetry(attempt: attempt)])
        case (.connected, .socketClosed):
            return (.backingOff(attempt: 1), [.publish(.retrying(attempt: 1)), .scheduleRetry(attempt: 1)])
        case let (.backingOff(attempt), .retryTimerFired):
            let next = attempt + 1
            return (.connecting(attempt: next), [.publish(.connecting(attempt: next)), .openSocket])
        case (.connected, .stop), (.connecting, .stop):
            return (.stopped, [.closeSocket, .publish(.stopped)])
        case (.backingOff, .stop), (.idle, .stop):
            return (.stopped, [.publish(.stopped)])
        default:
            return (state, [])
        }
    }
}
