import SwiftUI
import WatchKit
import HollerFeatures

@main
struct HollerWatchApp: App {
    @State private var root = WatchRoot()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = root.viewModel {
                    NavigationStack { ChannelScreen(model: model) }
                } else {
                    ConfigurationErrorView(message: root.errorMessage ?? "Starting…")
                }
            }
            .task { await root.start(displayName: WKInterfaceDevice.current().name) }
        }
    }
}
