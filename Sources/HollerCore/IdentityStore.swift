public import Foundation

/// Who this device is on the channel. Stable across launches.
public protocol IdentityStoring: Sendable {
    func participant() -> Participant
}

/// Persists a generated participant id in UserDefaults; the display name comes from the caller (device name).
public struct UserDefaultsIdentityStore: IdentityStoring {
    public static let idKey = "holler.participant.id"
    private let store: any KeyValueStoring
    private let displayName: String

    public init(store: any KeyValueStoring, displayName: String) {
        self.store = store
        self.displayName = displayName
    }

    public func participant() -> Participant {
        if let existing = store.string(forKey: Self.idKey) {
            return Participant(id: ParticipantID(existing), displayName: displayName)
        }
        let fresh = UUID().uuidString.lowercased()
        store.set(fresh, forKey: Self.idKey)
        return Participant(id: ParticipantID(fresh), displayName: displayName)
    }
}
