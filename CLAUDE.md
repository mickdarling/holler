# Holler — agent instructions

Read `CONTRIBUTING.md` first; it is binding. Then:

- Activate the Dollhouse ensemble `apple-product-team` and the memory `holler-project-context` before working here. They carry the component-design rules, the issue-spec process, the verification loop, and dated Apple-platform facts.
- The spec for any work is a GitHub issue. If there is no `status:ready` issue for what you are asked to do, write one (Feature spec template) before writing code.
- Keep PRs small: a file or two, three or four when wiring is unavoidable. Never tens of files; split the issue instead.
- Review with the Dollhouse ensemble `production-code-review-team` once per change, before commit/PR; record findings and evidence in the PR. One pass, fix, commit, stop — no review loop. Codex threads get a decision (fixed / declined with reason / tracked in an issue) and are resolved; they do not get fix commits by default. CI confirms; it must not discover.
- Run `scripts/verify.sh all` before opening a PR and paste the tail into the PR body. For changes in `Sources/HollerFeatures`, `Sources/HollerPTT`, `Sources/HollerAudio`, or `Apps/`, also run `scripts/verify.sh sim`.
- `xcodebuild` on this machine needs the Xcode license accepted; until then `scripts/verify.sh` falls back to the Command Line Tools toolchain with Xcode's Testing frameworks, and the simulator lane runs in CI only.
- Never hand-edit `Holler.xcodeproj`; edit `project.yml` and run `xcodegen generate`.
- Merge a PR yourself once the gate is green: required checks pass, zero open code-scanning alerts, every review thread answered and resolved, acceptance checklist complete. Rebase merge by default (linear history). Never merge past a red or pending check.
- Keep prose in docs and issues factual. No taglines.
