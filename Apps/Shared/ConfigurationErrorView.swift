import SwiftUI

/// Shown when the relay URL is missing from Info.plist (HollerRelayURL). Factual, no dead ends.
struct ConfigurationErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Holler is not configured").font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center)
        }
        .padding()
    }
}
