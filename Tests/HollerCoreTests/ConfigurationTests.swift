import Foundation
import Testing
import HollerCoreTestSupport
@testable import HollerCore

@Suite("Configuration")
struct ConfigurationTests {
    @Test("builds the channel socket URL from relay base, channel, and identity")
    func load() throws {
        let store = InMemoryKeyValueStore([ConfigurationLoader.channelKey: "kitchen"])
        let identity = UserDefaultsIdentityStore(store: store, displayName: "Mick's iPhone")
        let loader = ConfigurationLoader(info: [ConfigurationLoader.relayURLKey: "wss://relay.example"], store: store, identity: identity)
        let config = try loader.load()
        #expect(config.channelSocketURL.absoluteString == "wss://relay.example/v0/channels/kitchen/ws")
        #expect(config.participant.displayName == "Mick's iPhone")
        #expect(config.channel.name == "kitchen")
    }

    @Test("channel defaults to home")
    func defaultChannel() throws {
        let store = InMemoryKeyValueStore()
        let loader = ConfigurationLoader(info: [ConfigurationLoader.relayURLKey: "wss://relay.example"], store: store,
                                         identity: UserDefaultsIdentityStore(store: store, displayName: "A"))
        #expect(try loader.load().channel.id == ChannelID("home"))
    }

    @Test("identity is stable across loads and persisted")
    func stableIdentity() {
        let store = InMemoryKeyValueStore()
        let identity = UserDefaultsIdentityStore(store: store, displayName: "A")
        let first = identity.participant()
        #expect(first.id == identity.participant().id)
        #expect(store.string(forKey: UserDefaultsIdentityStore.idKey) == first.id.rawValue)
    }

    @Test("missing or non-websocket relay URL is rejected")
    func rejects() {
        let store = InMemoryKeyValueStore()
        let identity = UserDefaultsIdentityStore(store: store, displayName: "A")
        #expect(throws: ConfigurationError.missingRelayURL) {
            try ConfigurationLoader(info: [:], store: store, identity: identity).load()
        }
        #expect(throws: ConfigurationError.invalidRelayURL("https://relay.example")) {
            try ConfigurationLoader(info: [ConfigurationLoader.relayURLKey: "https://relay.example"],
                                    store: store, identity: identity).load()
        }
    }
}
