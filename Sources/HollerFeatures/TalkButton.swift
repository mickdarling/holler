public import SwiftUI
public import HollerCore

/// The one control that matters: press and hold to talk. Works with a finger, the Digital Crown click is not required.
public struct TalkButton: View {
    public let state: TalkMachine.State
    public let enabled: Bool
    public let onPress: () -> Void
    public let onRelease: () -> Void
    @GestureState private var isPressed = false

    public init(
        state: TalkMachine.State, enabled: Bool,
        onPress: @escaping () -> Void, onRelease: @escaping () -> Void
    ) {
        self.state = state
        self.enabled = enabled
        self.onPress = onPress
        self.onRelease = onRelease
    }

    public var body: some View {
        Circle()
            .fill(fill)
            .overlay(Image(systemName: symbol).font(.largeTitle).foregroundStyle(.white))
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.5)
            .gesture(pressGesture)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, pressed, _ in
                if !pressed {
                    pressed = true
                    onPress()
                }
            }
            .onEnded { _ in onRelease() }
    }

    private var fill: Color {
        switch state {
        case .transmitting: .red
        case .requesting: .orange
        case .receiving: .blue
        case .idle: enabled ? .accentColor : .gray
        }
    }

    private var symbol: String {
        switch state {
        case .transmitting, .requesting: "mic.fill"
        case .receiving: "speaker.wave.2.fill"
        case .idle: "mic"
        }
    }

    private var label: String {
        switch state {
        case .transmitting: "Transmitting, release to stop"
        case .requesting: "Requesting to talk"
        case .receiving: "Receiving"
        case .idle: "Hold to talk"
        }
    }
}
