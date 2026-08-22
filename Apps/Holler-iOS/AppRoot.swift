import Foundation
import HollerCore
import HollerAudio
import HollerPTT
import HollerFeatures
import Observation

/// iOS composition root: SessionServices + PushToTalk gating + audio session policy.
@MainActor
@Observable
final class AppRoot {
    private(set) var viewModel: TalkViewModel?
    private(set) var errorMessage: String?
    private var services: SessionServices?
    private var gate: PushToTalkGatedControl?

    func start(displayName: String) async {
        do {
            let configuration = try SessionServices.loadConfiguration(displayName: displayName)
            let services = SessionServices(configuration: configuration)
            let adapter = PushToTalkChannelAdapter()
            let gate = PushToTalkGatedControl(inner: services.coordinator, service: adapter, channel: configuration.channel.id)
            try AudioSessionConfigurator().configureForPushToTalk()
            _ = await AudioSessionConfigurator().requestRecordPermission()
            try await gate.start(channelName: configuration.channel.name)
            self.services = services
            self.gate = gate
            viewModel = services.makeViewModel(control: gate)
            await services.start()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
