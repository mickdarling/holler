# Holler wire protocol (v0)

Transport: one WebSocket per client to the relay, text frames, one JSON object per frame.
Encoding is Swift `Codable` enum synthesis of `WireMessage` (Sources/HollerCore/WireMessage.swift):
the object has exactly one key — the case name — whose value is an object of the labeled associated values.
`ChannelID` and `ParticipantID` encode as plain strings. `AudioFrame.payload` is base64 (`Data`).

| Direction | Message | JSON |
|---|---|---|
| client→relay | hello | `{"hello":{"participant":{"id":"p1","displayName":"Mick"},"channel":"kitchen"}}` |
| relay→client | welcome | `{"welcome":{"participants":[{"id":"p2","displayName":"Becca"}]}}` |
| relay→all | participantJoined | `{"participantJoined":{"participant":{"id":"p1","displayName":"Mick"}}}` |
| relay→all | participantLeft | `{"participantLeft":{"id":"p1"}}` |
| client→relay | floorRequest | `{"floorRequest":{"from":"p1"}}` |
| relay→all | floorGranted | `{"floorGranted":{"to":"p1"}}` |
| relay→requester | floorDenied | `{"floorDenied":{"to":"p1","heldBy":"p2"}}` |
| client→relay, relay→all | floorReleased | `{"floorReleased":{"by":"p1"}}` |
| client→relay, relay→others | audio | `{"audio":{"from":"p1","frame":{"sequence":7,"timestampMilliseconds":1724190000000,"payload":"AQID"}}}` |
| either | ping / pong | `{"ping":{"nonce":42}}` / `{"pong":{"nonce":42}}` |

## Relay rules (floor control)
1. A channel has at most one floor holder.
2. `floorRequest` when the floor is free → relay records holder, broadcasts `floorGranted{to}` to **everyone** (including the requester; the requester's TalkMachine treats a grant to itself as "granted" and a grant to others as "remoteStarted").
3. `floorRequest` while held by someone else → relay sends `floorDenied{to:requester, heldBy:holder}` to the requester only.
4. `floorReleased{by}` from the holder → relay clears the holder and broadcasts `floorReleased{by}`. From a non-holder → ignored.
5. `audio` from the holder → relay forwards to every other participant on the channel. From a non-holder → dropped.
6. A holder that disconnects → relay clears the floor and broadcasts `floorReleased{by}` then `participantLeft{id}`.
7. Relay answers `ping` with `pong` (same nonce); relay may ping idle clients and drop them after 2 missed pongs.
8. Frames larger than 16 KiB or malformed JSON → relay closes the socket with code 1003.

## Wake-up (iOS PushToTalk)
When a `floorGranted` happens, the relay sends an APNs push (`apns-push-type: pushtotalk`, topic `<bundle-id>.voip-ptt`) to every
participant on the channel whose socket is absent, payload `{"speaker":"p2","speakerName":"Becca","channel":"kitchen"}`.
The app's PushToTalk adapter turns that into `activeRemoteParticipant` and reconnects. Push sending is a relay feature flag
(`APNS_ENABLED`) and needs an APNs token-auth key configured as a secret.
