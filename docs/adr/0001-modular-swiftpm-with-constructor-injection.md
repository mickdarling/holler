# ADR-0001: Modular SwiftPM layers with protocol seams and constructor injection

- Status: Accepted
- Date: 2026-08-20
- Issue: n/a (founding decision)

## Context
The app must ship on iOS, watchOS, and macOS from one codebase, be verifiable component by component, and stay at zero static-analysis findings (SwiftLint, CodeQL Swift, SonarCloud if added). Large files and hidden dependencies are what produce those findings.

## Decision
Four layers (core → adapter → feature → app) as SwiftPM targets. Every external capability is a protocol in `HollerCore` with an adapter implementation and a hand-written fake. Dependencies are passed through `init`; the only place concrete adapters meet is the app target's composition root. Size limits (200-line files, 40-line functions) are SwiftLint errors. The module graph is declared in `docs/module-graph.yml` and enforced by a script.

## Consequences
More files and protocols than a monolith; every component builds and tests alone; platform-specific code is confined to adapters and app roots; the health-verifier loop can report per component.

## Alternatives considered
Single app target with folders (no enforcement); a DI container library (adds a dependency and runtime resolution for no gain at this size); Tuist (heavier than XcodeGen for three targets).

## How we will know it was right
`scripts/verify.sh all` stays green with zero lint exemptions, and CodeQL reports zero alerts across the first ten merged PRs.
