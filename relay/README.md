# Holler relay

Reference relay server for the Holler push-to-talk wire protocol (`docs/wire-protocol.md`).
It is a Cloudflare Worker plus one Durable Object per channel (`ChannelRoom`), written in
strict TypeScript. Like the rest of the repository it is licensed under AGPL-3.0.

## What it does

- `GET /v0/channels/:channelId/ws` with `Upgrade: websocket` connects a client to the channel's
  Durable Object (`idFromName(channelId)`). Every other path returns 404; the WebSocket path
  without an upgrade returns 426; `GET /healthz` returns `{"ok":true}`.
- The Durable Object uses the WebSocket Hibernation API (`acceptWebSocket`, `webSocketMessage`,
  `webSocketClose`, `webSocketError`). Per-socket participant state is kept in the socket
  attachment (`serializeAttachment`) and the floor holder and push tokens in DO storage, so the
  object can be evicted between messages without losing state.
- Floor control (`src/floor.ts`) is a pure state machine (`applyFloor(state, event)` returning
  `{state, effects}`); the DO only executes the effects. Rules implemented as in
  `docs/wire-protocol.md`: one holder per channel; grant broadcast to everyone including the
  requester; deny to the requester only; release from a non-holder ignored; audio forwarded only
  from the holder, to every other participant; a disconnecting holder produces
  `floorReleased{by}` then `participantLeft{id}`; `ping` is answered with `pong`; frames over
  16 KiB, binary frames, or malformed/unknown JSON close the socket with 1003.

Additional relay behaviour not spelled out in the wire protocol:

| Situation | Relay behaviour |
|---|---|
| Any message other than `hello`/`ping` before `hello` | close 1008 |
| `hello.channel` differs from the URL channel | close 1008 |
| Second `hello` on the same socket | ignored |
| New socket says `hello` with an id already connected | old socket closed with 4000 (`superseded`); no `participantLeft` is broadcast for it |
| `floorRequest` from the current holder | `floorGranted{to}` re-sent to the requester only; no state change |
| `floorRequest`/`floorReleased`/`audio` whose id is not the sender's own | dropped |
| Relay-only messages (`welcome`, `floorGranted`, ...) sent by a client | dropped |
| `ping.nonce` above 2^53-1 | rejected as malformed (JavaScript number precision) |

## Wire-protocol extension (v0, relay-specific)

`registerPushToken` — client to relay, sent any time after `hello`:

```json
{"registerPushToken":{"participantId":"p1","token":"<hex APNs PushToTalk device token>"}}
```

The relay stores the token per channel keyed by participant id (storage key `push:<id>`), and
ignores the message if `participantId` is not the sender's own id. When a `floorGranted` happens,
the relay sends one APNs push per registered participant whose socket is absent from the channel,
with `apns-push-type: pushtotalk`, the configured `apns-topic`, and body
`{"speaker":"p1","speakerName":"Mick","channel":"kitchen"}`. The client sends nothing back; the
relay never sends `registerPushToken`. Clients that do not register a token are never pushed.

## Running locally

```sh
cd relay
npm install
npx wrangler dev            # http://localhost:8787
```

Connect with any WebSocket client, e.g. `websocat ws://localhost:8787/v0/channels/kitchen/ws`,
then send `{"hello":{"participant":{"id":"p1","displayName":"Mick"},"channel":"kitchen"}}`.

Scripts:

| Command | Purpose |
|---|---|
| `npm run dev` | `wrangler dev` with local Durable Objects |
| `npm test` | vitest in the Workers runtime (`@cloudflare/vitest-pool-workers`): unit tests for `floor.ts`, `protocol.ts`, `es256.ts`/`apns.ts`, and end-to-end WebSocket tests through the Worker and DO, including eviction |
| `npm run typecheck` | regenerates `worker-configuration.d.ts` (`wrangler types`) and runs `tsc --noEmit` |
| `npm run deploy` | `wrangler deploy` (needs a logged-in `wrangler`) |

## Deploying

```sh
cd relay
npx wrangler login
npx wrangler deploy
```

`wrangler.jsonc` names the Worker `holler-relay`, binds `CHANNEL` to the `ChannelRoom` class and
declares the SQLite-backed Durable Object migration (`new_sqlite_classes`). The client should use
`wss://<your-worker-host>/v0/channels/<channelId>/ws`.

## Configuration

Non-secret variables live in `wrangler.jsonc` (`vars`); secrets are set with
`wrangler secret put <NAME>` for the deployed Worker, or in a local `.dev.vars` file for
`wrangler dev` (see `.dev.vars.example`; `.dev.vars` and `*.p8` are gitignored).

| Name | Kind | Meaning |
|---|---|---|
| `APNS_ENABLED` | var | `"true"` enables APNs wake-up pushes; anything else uses a no-op sender |
| `APNS_KEY_ID` | secret | Key ID of the APNs token-auth key |
| `APNS_TEAM_ID` | secret | Apple Developer Team ID |
| `APNS_PRIVATE_KEY` | secret | Contents of the `.p8` file (PKCS#8 PEM; literal `\n` escapes accepted) |
| `APNS_TOPIC` | secret | PushToTalk topic, `<bundle-id>.voip-ptt` |
| `APNS_HOST` | secret, optional | `api.push.apple.com` (default) or `api.sandbox.push.apple.com` |

The provider JWT (ES256) is signed with WebCrypto and cached for 50 minutes. If `APNS_ENABLED`
is `"true"` but a secret is missing, the relay logs a warning and runs with the no-op sender.

## Layout

```
src/index.ts        Worker entrypoint and routing
src/channel-room.ts ChannelRoom Durable Object (sockets, storage, effect execution)
src/socket-state.ts Socket attachment helpers and roster derivation
src/floor.ts        Pure floor-control state machine
src/protocol.ts     Wire types, parseMessage validator, encode
src/routing.ts      Path parsing shared by Worker and DO
src/apns.ts         WakeSender interface, NoopWakeSender, ApnsWakeSender
src/es256.ts        PEM parsing and ES256 JWT signing (WebCrypto)
src/env.ts          Environment/secret typings
test/               vitest suites
```
