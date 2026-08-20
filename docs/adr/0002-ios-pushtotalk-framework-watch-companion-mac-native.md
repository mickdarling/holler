# ADR-0002: iOS uses the PushToTalk framework; watchOS is foreground-first; macOS is a native client

- Status: Accepted
- Date: 2026-08-20
- Issue: n/a (founding decision)

## Context
"Always on, never disconnects" on iOS is only achievable through Apple's PushToTalk framework (iOS 16+): it provides background audio activation and APNs `pushtotalk` wake-ups. It is iOS-only. watchOS has no equivalent, limits background recording, and Apple is removing its own Walkie-Talkie app in watchOS 27. macOS has no system PTT service but no background restrictions either. (Facts verified 2026-08-20; see the Dollhouse memory `apple-platform-facts`.)

## Decision
iOS: `HollerPTT` wraps `PTChannelManager`; presses go through the system service (`PushToTalkGatedControl`) so capture starts only after the system confirms transmission. Audio session: playAndRecord, no `.mixWithOthers`. watchOS: connects to the relay directly; talk works in the foreground; background receive is best-effort via the `audio` background mode. macOS: AVAudioEngine client over the same transport.

## Consequences
iOS gets true background PTT; the Watch is honest about its limits rather than pretending; one Core serves all three.

## Alternatives considered
CallKit/VoIP push for iOS (deprecated path for PTT, App Review risk); WatchConnectivity relay through the iPhone for the Watch (adds a dependency on the phone being nearby; may be added later as an option).

## How we will know it was right
On iOS, a transmission from another participant wakes a backgrounded Holler and plays audio within 2 s in ≥ 95% of trials on device (spike issue).
