#if os(iOS) || os(watchOS)
public import AVFoundation

/// Configures the shared audio session for push-to-talk. Category/options follow Apple DTS guidance for the
/// PushToTalk framework: playAndRecord, no .mixWithOthers (it prevents background activation).
public struct AudioSessionConfigurator: Sendable {
    public init() {}

    public func configureForPushToTalk() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothA2DP])
        #endif
    }

    public func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
