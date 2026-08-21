# ADR-0005: The system push-to-talk service sits behind a protocol seam

- Status: Accepted
- Date: 2026-08-21
- Issue: #2 (also #26)

## Context
`PushToTalkGatedControl` decides when the coordinator may capture, whether to rejoin the system channel after the service drops it, and what the system UI shows as the remote speaker. With the gate bound to `PushToTalkChannelAdapter` (a `PTChannelManager` wrapper), none of that was testable: `PTChannelManager` only exists on iOS devices/simulators and cannot be scripted, and the whole module compiled to a marker elsewhere, so `HollerPTT` had no test target (#26).

## Decision
`PushToTalkChannelControlling` (events stream + prepare/join/leave/requestBeginTransmitting/stopTransmitting/setActiveSpeaker) is the seam. The adapter conforms on iOS; the gate depends only on the protocol and is platform-neutral, as is `PushToTalkEvent` (system leave reasons are a typed enum, `PushToTalkLeaveReason`). `HollerPTTTests` runs on every platform with `FakePushToTalkChannel` and is also in the Holler-iOS simulator scheme.

## Consequences
Gate behaviour (press gating, system-callback routing, rejoin policy, speaker mirroring, stop during an in-flight rejoin) is unit-tested with a fake. Apps keep naming one concrete adapter (composition root only). One more protocol to keep in step with the adapter.

## Alternatives considered
Testing through the simulator only (no scripting of leave/transmit callbacks); keeping the gate iOS-only and asserting the marker elsewhere (no behavioural coverage).

## How we will know it was right
`scripts/health.sh` shows HollerPTT Tests ✅ on macOS and the simulator lane; gate regressions fail a unit test before CI.
