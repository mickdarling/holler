/// Stable identifier for a push-to-talk channel (a "room" everyone on it hears).
public struct ChannelID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Stable identifier for a participant (one device/user on a channel).
public struct ParticipantID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A participant as shown to others on the channel.
public struct Participant: Hashable, Sendable, Codable {
    public let id: ParticipantID
    public let displayName: String
    public init(id: ParticipantID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A channel as shown in the UI.
public struct Channel: Hashable, Sendable, Codable {
    public let id: ChannelID
    public let name: String
    public init(id: ChannelID, name: String) {
        self.id = id
        self.name = name
    }
}
