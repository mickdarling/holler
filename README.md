# Holler

A simple, always-on push-to-talk (walkie-talkie) app for iPhone, iPad, Apple Watch, and Mac. One channel, one button, hold to talk. Open source under the AGPL-3.0.

Status (2026-08-20): v0 skeleton. Core logic, transport, audio adapters, SwiftUI screen, and app shells exist and the package test suite is green (58 tests). Nothing has been run on a device yet. See the issues list for the roadmap; every feature is specified as a GitHub issue.

## Why

Apple is removing the Apple Watch Walkie-Talkie app in watchOS 27 (reported 2026-07-10). Existing third-party push-to-talk apps are built for enterprise fleets. Holler is for a household or a small group: it stays connected, it does one thing, and you can run your own relay.

## How it works

- **iPhone/iPad**: the system PushToTalk framework (iOS 16+) provides the system talk UI, background audio, and APNs `pushtotalk` wake-ups. Holler's `HollerPTT` adapter wraps it.
- **Apple Watch**: connects to the relay directly; talk is foreground-first (watchOS has no PushToTalk framework and limits background recording).
- **Mac**: native AVAudioEngine client.
- **Relay**: a small Cloudflare Worker + Durable Object (`relay/`) that does floor control (one speaker at a time) and fan-out over WebSockets. Self-hosting is the intended deployment; the wire protocol is documented in `docs/wire-protocol.md`.
- **Reliability**: every connection is owned by a `ConnectionSupervisor` driving a pure `ConnectionMachine` state machine with jittered exponential backoff that never gives up. Talk state is a second pure state machine (`TalkMachine`). Both are exhaustively unit-tested.

## Architecture

Swift 6.2, SwiftPM modules, XcodeGen-generated app targets. Layers, enforced by `scripts/check-boundaries.sh` against `docs/module-graph.yml`:

```
HollerCore        pure Swift: domain types, wire protocol, state machines, supervisor, coordinator
HollerTransport   WebSocket adapter (URLSessionWebSocketTask)
HollerAudio       AVAudioEngine capture/playback, PCM codec, audio session policy
HollerPTT         Apple PushToTalk framework adapter (iOS only)
HollerFeatures    SwiftUI views + @Observable view model
Apps/             composition roots only (iOS, watchOS, macOS)
relay/            Cloudflare Worker + Durable Object
```

Every dependency crosses a protocol seam and is injected through `init`. Files are capped at 200 lines, functions at 40, enforced by SwiftLint. Details: `docs/architecture.md`, decisions: `docs/adr/`.

## Build

Requirements: Xcode 26.x (license accepted), Homebrew.

```sh
brew bundle                 # xcodegen, swiftlint, periphery, xcbeautify
scripts/verify.sh all       # build, test, lint, dead code, module boundaries, file size
scripts/verify.sh sim       # generate the Xcode project and run the iOS/watchOS/macOS app schemes on simulators
xcodegen generate && open Holler.xcodeproj
```

The relay URL is baked into each app's Info.plist from the `HOLLER_RELAY_URL` build setting in `project.yml`.

## Contributing

Specs live in GitHub issues (use the Feature spec template). One issue → one branch → one PR that closes it. `scripts/verify.sh all` must be green locally and in CI; CodeQL must report zero new alerts. See `CONTRIBUTING.md`.

## License

AGPL-3.0-or-later. See `LICENSE`.
