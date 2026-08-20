public import Foundation

/// Everything the composition root needs to build a session. Loaded once at launch.
public struct HollerConfiguration: Sendable, Equatable {
    public let relayBaseURL: URL
    public let channel: Channel
    public let participant: Participant

    public init(relayBaseURL: URL, channel: Channel, participant: Participant) {
        self.relayBaseURL = relayBaseURL
        self.channel = channel
        self.participant = participant
    }

    /// wss://host/v0/channels/<channel>/ws
    public var channelSocketURL: URL {
        relayBaseURL.appending(path: "v0/channels/\(channel.id.rawValue)/ws")
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case missingRelayURL
    case invalidRelayURL(String)
}

/// Builds a configuration from an Info.plist-style dictionary plus persisted identity/channel preferences.
public struct ConfigurationLoader: Sendable {
    public static let relayURLKey = "HollerRelayURL"
    public static let channelKey = "holler.channel"

    private let info: [String: String]
    private let store: any KeyValueStoring
    private let identity: any IdentityStoring

    public init(info: [String: String], store: any KeyValueStoring, identity: any IdentityStoring) {
        self.info = info
        self.store = store
        self.identity = identity
    }

    public func load() throws(ConfigurationError) -> HollerConfiguration {
        guard let raw = info[Self.relayURLKey], !raw.isEmpty else { throw ConfigurationError.missingRelayURL }
        guard let url = URL(string: raw), let scheme = url.scheme, ["ws", "wss"].contains(scheme) else {
            throw ConfigurationError.invalidRelayURL(raw)
        }
        let channelName = store.string(forKey: Self.channelKey) ?? "home"
        let channel = Channel(id: ChannelID(channelName), name: channelName)
        return HollerConfiguration(relayBaseURL: url, channel: channel, participant: identity.participant())
    }
}
