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

    private var starting = false

    func start(displayName: String) async {
        guard !starting else { return }  // a second start while one is in flight would orphan a joined gate
        starting = true
        defer { starting = false }
        // Restart: clear the fields before suspending (a re-entrant start must not see the old gate), then tear down.
        var previousGate = gate, previousServices = services
        gate = nil; services = nil; viewModel = nil
        await previousGate?.stop()
        await previousServices?.stop()
        // released before a new adapter is built: one PTChannelManager at a time
        previousGate = nil; previousServices = nil
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
