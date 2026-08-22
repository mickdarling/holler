# ADR-0005: The system push-to-talk service sits behind a protocol seam

- Status: Accepted
- Date: 2026-08-21
- Issue: #2 (also #26)

## Context
`PushToTalkGatedControl` decides when the coordinator may capture, whether to rejoin the system channel after the service drops it, and what the system UI shows as the remote speaker. With the gate bound to `PushToTalkChannelAdapter` (a `PTChannelManager` wrapper), none of that was testable: `PTChannelManager` only exists on iOS devices/simulators and cannot be scripted, and the whole module compiled to a marker elsewhere, so `HollerPTT` had no test target (#26).

## Decision
`PushToTalkChannelControlling` is the seam: an `events` stream plus `prepare/join/leave/requestBeginTransmitting/stopTransmitting/setActiveSpeaker`. Commands throw `PushToTalkServiceError` (`.notPrepared`, `.unknownChannel`) when they cannot be issued; outcomes arrive as events, mirroring the framework's delegate: `.joined`/`.joinFailed`, `.left(reason)` (typed `PushToTalkLeaveReason`)/`.leaveFailed`, `.beginTransmittingRequested`/`.endTransmittingRequested`, `.beginTransmitFailed`/`.stopTransmitFailed`, `.incomingSpeaker`, `.audioSessionActivated`/`.audioSessionDeactivated`, `.pushTokenUpdated`. The adapter conforms on iOS; the gate depends only on the protocol and is platform-neutral. `events` is single-consumer and created once: the gate owns the only subscription (its pumps live for the gate's lifetime).

The gate's model: `start()`/`stop()`/rejoin are serialized FIFO; transmit callbacks are forwarded only while the system has confirmed membership; our own leave confirmations are accounted for so a late one cannot end the next membership; a join refused while our leave was in flight is retried once the leave confirms; a terminal leave (`.userRequest`/`.systemPolicy`; `.developerRequest` is the app's own and not final) of a membership the session holds (confirmed `.joined`, no join outstanding) is final until the next `start()` — no rejoin, and a retired join accepted late is left again (bounded retries) and never adopted; a `.left` while a join is unanswered (a restart or rejoin in flight) concerns the membership being replaced (the framework answers a join before it can report leaving that membership) and leaves the standing request unaffected; speaker mirroring runs on one worker, never during a system transmission, and the gate stops the system transmission when the coordinator drops the floor on its own.

`HollerPTTTests` runs on every platform with `FakePushToTalkChannel` (which, like the framework, answers `join`/`leave` with `.joined`/`.left`) and is also in the Holler-iOS simulator scheme, where a selector-spelling test covers the adapter's optional delegate methods.

## Consequences
Gate behaviour is unit-tested with a fake (60+ tests across membership, sessions, speaker mirroring, lifecycle overlap, restarts, terminal leaves). Apps keep naming one concrete adapter (composition root only); `AppRoot` stops the previous gate and session services before restarting. One more protocol to keep in step with the adapter.

Assumption the membership bookkeeping relies on: the framework answers every `requestJoinChannel` exactly once and in order (`didJoinChannel` or `failedToJoinChannel`); the gate correlates answers to requests by count and retires unanswered requests on `stop()`. Known gaps (tracked as follow-ups): the gate ignores `.audioSessionActivated`/`.audioSessionDeactivated` and `.pushTokenUpdated` — because `events` is single-consumer, nothing else can consume them today, so APNs push registration (#6) needs either a second consumer or a forwarding hook; channel restoration (`channelDescriptor(restoredChannelUUID:)`) returns a descriptor without seeding the adapter's UUID map; a push payload without a `speaker` field makes the adapter leave the channel (PTPushResult offers no other non-participant answer); a rejoin whose join throws is not retried until the next start; after a terminal leave the app shows no membership state and offers no reconnect (the talk button is silently inert until the next start), and if the system refuses every cleanup leave the gate stays not-joined while the system still holds the membership — a desync with no resync path (#38).

## Alternatives considered
Testing through the simulator only (no scripting of leave/transmit callbacks); keeping the gate iOS-only and asserting the marker elsewhere (no behavioural coverage).

## How we will know it was right
`scripts/health.sh` shows HollerPTT Tests ✅ on macOS and the simulator lane; gate regressions fail a unit test before CI.
