/// Half-duplex floor control on the client: press -> request -> granted -> transmit -> release.
/// Receiving is exclusive with transmitting. Pure; the coordinator interprets effects.
public struct TalkMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case requesting
        case transmitting
        case receiving(from: ParticipantID)
    }

    public enum Event: Sendable, Equatable {
        case pressed
        case released
        case granted
        case denied(heldBy: ParticipantID)
        case remoteStarted(ParticipantID)
        case remoteStopped(ParticipantID)
        case disconnected
    }

    public enum Effect: Sendable, Equatable {
        case sendFloorRequest
        case sendFloorRelease
        case startCapture
        case stopCapture
        case startPlayback(from: ParticipantID)
        case stopPlayback
        case notifyDenied(heldBy: ParticipantID)
    }

    public init() {}

    public func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch event {
        case .pressed, .released, .granted, .denied:
            return reduceLocal(state, event)
        case .remoteStarted, .remoteStopped, .disconnected:
            return reduceRemote(state, event)
        }
    }

    /// Events caused by this user's button and the relay's answer to it.
    private func reduceLocal(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch (state, event) {
        case (.idle, .pressed):
            return (.requesting, [.sendFloorRequest])
        case (.requesting, .granted):
            return (.transmitting, [.startCapture])
        case let (.requesting, .denied(holder)):
            return (.idle, [.notifyDenied(heldBy: holder)])
        case (.requesting, .released):
            return (.idle, [.sendFloorRelease])
        case (.transmitting, .released):
            return (.idle, [.stopCapture, .sendFloorRelease])
        case let (.receiving(current), .pressed):
            return (.receiving(from: current), [.notifyDenied(heldBy: current)])
        default:
            return (state, [])
        }
    }

    /// Events caused by other participants or the connection.
    private func reduceRemote(_ state: State, _ event: Event) -> (State, [Effect]) {
        switch (state, event) {
        case let (.idle, .remoteStarted(speaker)):
            return (.receiving(from: speaker), [.startPlayback(from: speaker)])
        case let (.receiving(current), .remoteStopped(speaker)) where current == speaker:
            return (.idle, [.stopPlayback])
        case (.transmitting, .disconnected):
            return (.idle, [.stopCapture])
        case (.receiving, .disconnected):
            return (.idle, [.stopPlayback])
        case (.requesting, .disconnected):
            return (.idle, [])
        default:
            return (state, [])
        }
    }
}
