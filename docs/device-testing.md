# Device testing — two phones talking

From zero to a first field test of Holler-iOS on real hardware. PushToTalk does not run in the
simulator, so this is the first time the talk path is exercised end to end. Status of the moving
parts is in `docs/agent/development/HANDOFF_2026-08-22.md`.

## Prerequisites (one-time)

1. **Apple team.** A paid Developer Program membership (Push to Talk is not available to free
   personal teams). Put the 10-character Team ID in `project.yml` (`DEVELOPMENT_TEAM`) and run
   `xcodegen generate`.
2. **Cloudflare.** `cd relay && npx wrangler login` (the relay deploys as a Worker named
   `holler-relay`).
3. **Phones.** Two iPhones on iOS 16 or later. On each: Settings → Privacy & Security →
   Developer Mode → on (reboots the phone). First install per phone needs USB.
4. **Mac toolchain.** Xcode with the license accepted;
   `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select points at the
   Command Line Tools on this machine).

## 1. Deploy the relay, bake its URL

```sh
cd relay
npm ci && npm test          # green before deploying
npx wrangler deploy         # prints https://holler-relay.<subdomain>.workers.dev
```

Set the printed host in `project.yml` (scheme `wss`, no trailing slash):

```yaml
HOLLER_RELAY_URL: "wss://holler-relay.<subdomain>.workers.dev"
```

then `xcodegen generate`. The app appends `/v0/channels/<channel>/ws` itself
(`HollerConfiguration.channelSocketURL`). Every phone with the same build joins channel `home` by
default (`ConfigurationLoader`; per-device channel choice is #10). Sanity check the deployed relay
from the Mac:

```sh
websocat "wss://holler-relay.<subdomain>.workers.dev/v0/channels/home/ws"   # connects, stays open
```

## 2. Build and install on each phone

Plug the phone in, trust the Mac on the phone, then:

```sh
xcrun devicectl list devices                     # copy the device identifier
xcodebuild -project Holler.xcodeproj -scheme Holler-iOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath .build/device build
xcrun devicectl device install app --device <identifier> \
  .build/device/Build/Products/Debug-iphoneos/Holler.app
```

The first build against a fresh team registers the device and the App ID (with the Push to Talk
capability from `Apps/Holler-iOS/Holler.entitlements`) via automatic signing; if it stalls on
"waiting for provisioning", open `Holler.xcodeproj` in Xcode once, select the Holler-iOS target →
Signing & Capabilities, and let it resolve, then rerun the command. On the phone, the first launch
asks to trust the developer certificate: Settings → General → VPN & Device Management.

## 3. The test

- Launch Holler on both phones (foreground). Each phone's participant name is its device name.
- Both join the system Push to Talk channel "home"; iOS shows the PTT pill/leading indicator.
- Hold the talk button on phone A: A's mic captures, B plays it; the system UI on B names A as
  the active speaker. Release; swap roles.
- Quick taps, overlapping presses, and route changes (speaker/earpiece/AirPods) are worth a pass.

## Expectations and known gaps

- **Foreground first.** Background receive without APNs (#6) is not wired; keep both apps
  foregrounded for this test. Background *transmit* through the system PTT UI may work (the
  `push-to-talk` background mode is set) — observe, don't rely.
- **#38:** if the system ends the channel membership (user leaves via the PTT system UI, another
  PTT app takes the channel), the talk button goes silently inert until the app is relaunched.
- A press during the begin/stop handshake windows can drop that one transmission (press again);
  the state model rework is #41.
- Restart teardown races are #49 — relaunch the app rather than toggling display names mid-test.
- Relay secrets: none needed for this test (`APNS_ENABLED` is `"false"` in `wrangler.jsonc`).

## Cleanup

`npx wrangler delete holler-relay` removes the Worker (the DO and its storage go with it).
