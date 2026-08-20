import SwiftUI
import UIKit
import HollerFeatures

@main
struct HollerApp: App {
    @State private var root = AppRoot()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = root.viewModel {
                    NavigationStack { ChannelScreen(model: model) }
                } else {
                    ConfigurationErrorView(message: root.errorMessage ?? "Starting…")
                }
            }
            .task { await root.start(displayName: UIDevice.current.name) }
        }
    }
}
