# Architecture

## Layers
`docs/module-graph.yml` is the authority; `scripts/check-boundaries.sh` enforces it.

| Layer | Modules | May import |
|---|---|---|
| core | HollerCore, HollerCoreTestSupport | Foundation, Synchronization |
| adapter | HollerTransport, HollerAudio, HollerPTT | one Apple framework each + HollerCore |
| feature | HollerFeatures | SwiftUI, Observation, HollerCore |
| app | Apps/Holler-iOS, Apps/Holler-watchOS, Apps/Holler-macOS, Apps/Shared | everything above |

## Core pieces
- `WireMessage` — the relay protocol (Codable enum, labeled keys). `docs/wire-protocol.md` is the human copy.
- `ConnectionMachine` + `ConnectionSupervisor` — connection lifecycle. The machine decides, the supervisor performs effects (open/close socket, schedule retry, publish health) and pumps transport events. `BackoffPolicy` is pure and jittered; jitter comes from an injected `RandomUnitSource`.
- `TalkMachine` + `TalkCoordinator` — half-duplex floor control on the client. Press → floor request → granted → capture → release. Receiving is exclusive with transmitting. The coordinator sends `hello` when health goes online, answers pings, keeps the roster, and plays audio only from the current speaker.
- `Broadcaster` — fan-out for AsyncStream subscribers (AsyncStream is single-consumer). `TaskBag` — owns tasks for main-actor types.
- Protocol seams: `SignalingTransport`, `AudioCapturing`, `AudioPlaying`, `AudioFrameCodec`, `Sleeper`, `RandomUnitSource`, `KeyValueStoring`, `IdentityStoring`, `TalkControlling`.

## Adapters
- `WebSocketSignalingTransport` over `URLSessionWebSocketTask`, behind `WebSocketConnecting`/`WebSocketChannel` so tests script the socket.
- `AVAudioEngineCapture` (input tap → `AVAudioConverter` → 16 kHz mono Int16 → `FrameEmitter`) and `AVAudioEnginePlayer` (player node). `PassthroughPCMCodec` is the baseline; Opus goes behind `AudioFrameCodec` later (issue).
- `PushToTalkChannelAdapter` wraps `PTChannelManager` (iOS only) and `PushToTalkGatedControl` decorates `TalkControlling` so presses go through the system service before capture starts.

## Apps
Composition roots only. `Apps/Shared/SessionServices.swift` wires config → transport → supervisor → coordinator; each platform root adds its platform pieces (PTT gate + audio session on iOS; audio session on watchOS; nothing extra on macOS).

## Verification
`scripts/verify.sh` is the single source of truth for local and CI verification. Components are health-checked individually by the Dollhouse `component-health-verifier` agent, which files `health` issues.
