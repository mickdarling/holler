public import SwiftUI
public import HollerCore

/// Connection indicator. Text is explicit so it reads on the Watch and in VoiceOver.
public struct HealthBadge: View {
    public let health: HealthState
    public init(health: HealthState) { self.health = health }

    public var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel("Connection \(title)")
    }

    private var title: String {
        switch health {
        case .online: "Online"
        case .offline: "Offline"
        case let .connecting(attempt): attempt > 1 ? "Connecting (\(attempt))" : "Connecting"
        case let .retrying(attempt): "Reconnecting (\(attempt))"
        case .stopped: "Stopped"
        }
    }

    private var symbol: String {
        switch health {
        case .online: "dot.radiowaves.left.and.right"
        case .offline, .stopped: "wifi.slash"
        case .connecting, .retrying: "arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch health {
        case .online: .green
        case .connecting, .retrying: .orange
        case .offline, .stopped: .secondary
        }
    }
}
