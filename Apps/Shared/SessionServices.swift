import Foundation
import HollerCore
import HollerTransport
import HollerAudio
import HollerFeatures

/// Platform-neutral composition: config -> transport -> supervisor -> coordinator. App targets add platform pieces.
@MainActor
final class SessionServices {
    let configuration: HollerConfiguration
    let supervisor: ConnectionSupervisor
    let coordinator: TalkCoordinator
    let transport: WebSocketSignalingTransport

    init(configuration: HollerConfiguration) {
        self.configuration = configuration
        let codec = PassthroughPCMCodec()
        transport = WebSocketSignalingTransport(url: configuration.channelSocketURL)
        supervisor = ConnectionSupervisor(transport: transport)
        coordinator = TalkCoordinator(
            participant: configuration.participant,
            channel: configuration.channel.id,
            transport: transport,
            capture: AVAudioEngineCapture(codec: codec),
            playback: AVAudioEnginePlayer(codec: codec)
        )
    }

    /// Load configuration from Info.plist + persisted preferences. Throws if the relay URL is not configured.
    static func loadConfiguration(displayName: String) throws -> HollerConfiguration {
        let info = (Bundle.main.infoDictionary ?? [:]).compactMapValues { $0 as? String }
        let store = UserDefaultsKeyValueStore()
        let identity = UserDefaultsIdentityStore(store: store, displayName: displayName)
        return try ConfigurationLoader(info: info, store: store, identity: identity).load()
    }

    func start() async {
        await coordinator.attach(messages: supervisor.subscribeMessages(), health: supervisor.subscribeHealth())
        await supervisor.start()
    }

    func makeViewModel(control: any TalkControlling) -> TalkViewModel {
        TalkViewModel(channelName: configuration.channel.name, control: control, health: supervisor.subscribeHealth())
    }
}
