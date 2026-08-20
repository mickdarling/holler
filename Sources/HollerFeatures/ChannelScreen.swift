public import SwiftUI
public import HollerCore

/// The whole app on one screen: who is here, connection state, and the talk button.
public struct ChannelScreen: View {
    @Bindable private var model: TalkViewModel

    public init(model: TalkViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            header
            Spacer(minLength: 0)
            TalkButton(state: model.talkState, enabled: model.canTalk || model.isTransmitting,
                       onPress: model.pressed, onRelease: model.released)
                .frame(maxWidth: 220, maxHeight: 220)
                .aspectRatio(1, contentMode: .fit)
            statusLine
            Spacer(minLength: 0)
            RosterList(participants: model.roster, speaker: model.speakerID)
        }
        .padding()
        .navigationTitle(model.channelName)
    }

    private var header: some View {
        HStack {
            Text(model.channelName).font(.headline)
            Spacer()
            HealthBadge(health: model.health)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let name = model.speakerName {
            Text("\(name) is talking").font(.subheadline)
        } else if case let .denied(holder) = model.lastNotice {
            let name = model.roster.first { $0.id == holder }?.displayName ?? holder.rawValue
            Text("Channel busy: \(name)").font(.subheadline).foregroundStyle(.orange)
        } else {
            Text(model.isTransmitting ? "You are talking" : "Hold to talk")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Compact roster; the current speaker is marked.
public struct RosterList: View {
    public let participants: [Participant]
    public let speaker: ParticipantID?
    public init(participants: [Participant], speaker: ParticipantID?) {
        self.participants = participants
        self.speaker = speaker
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(participants, id: \.id) { participant in
                HStack {
                    Image(systemName: participant.id == speaker ? "waveform" : "person")
                    Text(participant.displayName)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(participants.count) on channel")
    }
}
