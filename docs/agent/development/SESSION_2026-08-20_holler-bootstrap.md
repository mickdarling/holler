# Session Notes - August 20–21, 2026

Date: 2026-08-20 (evening) → 2026-08-21 (midday)
Focus: Forge the `apple-product-team` Dollhouse ensemble and bootstrap Holler (open-source PTT app) with issue-spec process, local==CI verification, and per-component health loop.
Outcome: Completed (bootstrap) / In Progress (#24 pending merge; process change to local review gate requested)

## Session Summary
Researched (web-verified, dated) Apple PushToTalk/watchOS/macOS constraints and 2026 Swift tooling; forged a reusable Apple product team in Dollhouse; created mickdarling/holler with a DI-structured Swift 6.2 core (connection + talk state machines, supervisor with jittered backoff and liveness watchdog), transport/audio/PTT adapters, SwiftUI features, XcodeGen apps, a Cloudflare Durable Object relay, CI/CodeQL, branch protection, 16 spec issues, ADRs, and a health-report script. Landed 10 PRs via a serialized merge watcher; addressed ~20 Codex review findings.

## Work Completed
### Dollhouse
- `apple-product-team` ensemble (16 elements) + `holler-project-context`; runbook lessons; merge policy update (author merges when gate green).
### Holler repo
- v0 skeleton (88e1f0f), relay (63321a6), CI fixes (#22), merge policy (#23), sim destinations (#28), handshake-accurate connected (#29), liveness watchdog (#27), Dependabot #16–#20, health script + baseline (#24, open).
- Issues #1–#15 specs, #21 (done), #25/#26 health, labels, templates.

## Key Decisions
- Layers core→adapter→feature→app with protocol seams + constructor injection (ADR-0001); PushToTalk on iOS, foreground-first Watch, native Mac (ADR-0002); WebSocket relay with server-side floor control on Cloudflare DO (ADR-0003); issues-as-specs + single verify script (ADR-0004).
- Author merges when gate green (Mick, 2026-08-21). New: local code-review ensemble before/after changes, before CI (Mick, 2026-08-21 — to implement next session).

## Issues and PRs
| Type | Number | Title | Status |
|------|--------|-------|--------|
| PR | #22 | verify.sh bash-3.2, strict lint, periphery | Merged |
| PR | #23 | merge policy + CodeQL concurrency | Merged |
| PR | #28 | UDID simulator destinations | Merged |
| PR | #29 | connected after handshake (closes #21) | Merged |
| PR | #27 | liveness watchdog (closes #5) | Merged |
| PR | #16–#20 | Dependabot (actions; TS 7 in relay) | Merged |
| PR | #24 | health script + baseline (#13) | Open, green, paused |
| Issue | #1 | Relay v0 | Closed |
| Issue | #5, #21 | liveness; connected signal | Closed |
| Issue | #2–#4, #6–#15, #25, #26 | roadmap/health | Open |

## Key Learnings
- See HANDOFF_2026-08-21.md Gotchas and the `apple-product-team-runbook` "Lessons" entries.

## Next Session Priorities
1. Bring the Production Code Review Team ensemble to this Mac (or rebuild) and wire it as the pre/post-change local gate; encode in runbook/agent/CONTRIBUTING.
2. Finish #24 through that gate and merge.
3. #2 iOS shell (+#26), #25, #10.
