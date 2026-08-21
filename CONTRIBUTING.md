# Contributing to Holler

## Specs are issues
Every feature starts as a GitHub issue using the **Feature spec** template: intent, observable behavior, testable acceptance criteria, component mapping (modules and protocol seams from `docs/module-graph.yml`), test expectations, out of scope. An issue is `status:ready` only when someone with no chat context could implement it from the issue alone. Keep specs PR-sized (one module seam, roughly under 300 lines of change); split otherwise.

## One issue, one branch, one PR
Branch from `main` as `feature/<issue>-<slug>` (or `fix/`, `chore/`). The PR body starts with `Closes #<issue>`, mirrors the acceptance criteria as a checklist, and pastes the tail of `scripts/verify.sh all`. Nobody pushes to `main` directly.

## Verification is one script
`scripts/verify.sh all` runs build, tests, SwiftLint (`--strict`), Periphery dead-code scan, the module-boundary check, and the file-size check. CI runs the same script on `macos-26`, plus `scripts/verify.sh sim` for the app schemes and CodeQL for Swift. A PR merges only when all of those are green and CodeQL reports zero new alerts. Install the pre-push hook with `scripts/install-hooks.sh`.

## Code rules (enforced)
- Protocol seams at every boundary; concrete types are `internal`; only `Apps/*` name more than one concrete adapter.
- Constructor injection only. No singletons, `.shared`, service locators, or global mutable state outside an adapter that wraps an Apple singleton.
- Files ≤ 200 lines, functions ≤ 40 lines, types ≤ 150 lines, cyclomatic complexity ≤ 10, ≤ 5 init parameters.
- Swift 6 strict concurrency: `Sendable` across boundaries, actors for shared state, `@MainActor` only on UI types.
- State with a lifecycle is a value-type state machine (`State`, `Event`, `reduce -> (State, [Effect])`) with exhaustive tests.
- Tests use Swift Testing and hand-written fakes from `HollerCoreTestSupport`; no sleeps — inject `Sleeper`.
- Forbidden: force unwrap/try/cast outside tests, `@unchecked Sendable`, empty `catch {}`, string-built URLs/commands, hardcoded secrets, logging audio payloads or tokens, TODO/FIXME without an issue number.

## Review and merge
The local review gate runs before CI sees anything: activate the Dollhouse ensemble `production-code-review-team` (element files and a no-Dollhouse fallback checklist in `docs/agent/dollhouse/production-code-review-team/`) and review the full diff against `main` **before** changing an existing branch and **again** after your changes, before commit/PR. Fix every confirmed finding, re-review the resulting diff (the whole affected code, not only the new lines), and record the findings (id, severity, location, finding, status) plus the evidence you executed in the PR. Any rebase, `gh pr update-branch`, or merge from `main` after that review invalidates it: the last local review must run on the exact state CI tests and you merge. CI confirms; it must not discover.

A Claude code review of the diff is the required gate (correctness, security, complexity); automated reviewers (Codex) are optional but every thread they open must be answered (what changed, which commit) and resolved. Record what the review found in the PR. When required checks are green, code-scanning alerts are zero, and all threads are resolved, the author (human or agent) merges — rebase by default, squash only when the branch history is noise — and deletes the branch.

## Relay
`relay/` is TypeScript on Cloudflare Workers. `npm ci && npm test && npm run typecheck` must pass. The wire protocol is in `docs/wire-protocol.md`; changing it changes `Sources/HollerCore/WireMessage.swift` and the relay in the same PR.
