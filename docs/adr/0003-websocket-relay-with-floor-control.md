# ADR-0003: WebSocket relay with server-side floor control; reference relay on Cloudflare Durable Objects

- Status: Accepted
- Date: 2026-08-20
- Issue: n/a (founding decision)

## Context
A walkie-talkie channel needs one speaker at a time and fan-out to everyone else. Peer-to-peer (WebRTC mesh) complicates NAT traversal and multi-device wake-ups; a relay keeps clients simple and lets the server send APNs wake pushes.

## Decision
JSON-over-WebSocket protocol (`docs/wire-protocol.md`) with the relay as floor arbiter. The reference relay is a Cloudflare Worker + Durable Object per channel using WebSocket Hibernation (near-zero idle cost), AGPL like the apps. Transport is behind `SignalingTransport`; the codec behind `AudioFrameCodec` (PCM16 first, Opus later).

## Consequences
Self-hosting requires a Cloudflare account or a port of the relay (the protocol is small); audio traverses the relay (no E2E encryption in v0 — tracked as a future feature); latency depends on the relay's edge location.

## Alternatives considered
WebRTC SFU (LiveKit etc.): far more capable, far heavier; self-hosted Swift relay (Hummingbird): viable, deferred until there is a non-Cloudflare user.

## How we will know it was right
A two-device round trip (press → audio heard) under 400 ms median on the same continent; relay idle cost under $1/month for a household.
