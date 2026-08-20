import Foundation
import HollerAudio
import HollerFeatures
import Observation

/// watchOS composition root: direct relay connection, foreground-first talk (no PushToTalk framework on watchOS).
@MainActor
@Observable
final class WatchRoot {
    private(set) var viewModel: TalkViewModel?
    private(set) var errorMessage: String?
    private var services: SessionServices?

    func start(displayName: String) async {
        do {
            let configuration = try SessionServices.loadConfiguration(displayName: displayName)
            let services = SessionServices(configuration: configuration)
            try AudioSessionConfigurator().configureForPushToTalk()
            _ = await AudioSessionConfigurator().requestRecordPermission()
            self.services = services
            viewModel = services.makeViewModel(control: services.coordinator)
            await services.start()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
