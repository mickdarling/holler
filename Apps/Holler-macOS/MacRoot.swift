import Foundation
import HollerFeatures
import Observation

/// macOS composition root: native AVAudioEngine client, no system PTT service.
@MainActor
@Observable
final class MacRoot {
    private(set) var viewModel: TalkViewModel?
    private(set) var errorMessage: String?
    private var services: SessionServices?

    func start(displayName: String) async {
        do {
            let configuration = try SessionServices.loadConfiguration(displayName: displayName)
            let services = SessionServices(configuration: configuration)
            self.services = services
            viewModel = services.makeViewModel(control: services.coordinator)
            await services.start()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
