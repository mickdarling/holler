# ADR-0004: GitHub issues are the spec; one verification script for local and CI

- Status: Accepted
- Date: 2026-08-20
- Issue: n/a (founding decision)

## Context
The project is developed largely by agents. Specs in chat are lost; CI that differs from local commands produces "works on my machine".

## Decision
Every feature is a GitHub issue in the Feature-spec template with testable acceptance criteria and a component mapping; `status:ready` means implementable from the issue alone. `scripts/verify.sh` is the only verification entry point; CI calls it. Merge gates: verify green, simulator lane green for UI/adapter changes, CodeQL zero new alerts, Claude review recorded in the PR.

## Consequences
Slightly more ceremony per change; full traceability issue → branch → PR → verification; agents can be run per issue without context.

## Alternatives considered
Specs in `docs/` (drift from issues); PR-only workflow (no durable acceptance criteria).

## How we will know it was right
Every merged PR closes exactly one issue and carries a pasted verification tail.
