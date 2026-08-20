/// What the UI shows about the connection. Derived from ConnectionMachine.State, never set directly.
public enum HealthState: Sendable, Equatable {
    case offline
    case connecting(attempt: Int)
    case online
    case retrying(attempt: Int)
    case stopped
}
