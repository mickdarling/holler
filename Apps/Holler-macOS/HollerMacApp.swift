import SwiftUI
import HollerFeatures

@main
struct HollerMacApp: App {
    @State private var root = MacRoot()

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = root.viewModel {
                    ChannelScreen(model: model)
                } else {
                    ConfigurationErrorView(message: root.errorMessage ?? "Starting…")
                }
            }
            .frame(minWidth: 320, minHeight: 420)
            .task { await root.start(displayName: Host.current().localizedName ?? "Mac") }
        }
    }
}
