# production-code-review-team — the local review gate

These are the Dollhouse element files that make up the `production-code-review-team` ensemble required by `CONTRIBUTING.md` (one review pass per change, before commit/PR; `CONTRIBUTING.md` governs where the element texts below describe a longer loop). They are plain Markdown with YAML front matter, exported 2026-08-21.

## Install (Dollhouse MCP server)
1. From the repository root, copy the files into your portfolio without overwriting anything you already have: `cp -Rn docs/agent/dollhouse/production-code-review-team/{ensembles,agents,skills,personas} ~/.dollhouse/portfolio/` (`-n` = no-clobber; the server's `import_element` operation with `overwrite: false` behaves the same). Then compare any same-named element you already had — `diff -r docs/agent/dollhouse/production-code-review-team/skills ~/.dollhouse/portfolio/skills` — and decide per file; the ensemble needs `code-review` ≥ 2.0.0 (Production Correctness section). Dollhouse keeps its own copies under `~/.dollhouse/portfolio/.backups/` when it edits an element, but `cp` does not, so never use `-f` here.
2. Activate: `activate_element` with `element_type: ensemble`, `element_name: production-code-review-team`. Expect 8/8 elements active (1 agent, 5 skills, 2 personas).
3. Review the diff; record findings (id, severity, location, finding, status) and the evidence you executed in the PR.

`security-analyst`, `technical-analyst`, `code-review`, and `threat-modeling` are DollhouseMCP-authored elements that may already exist in your portfolio; the versions here are the ones the ensemble was built against (code-review is v2.0.0 with the Production Correctness section).

## Fallback without Dollhouse
Apply the ensemble's required workflow by hand and record the same table in the PR:
1. Inventory trust, transaction, lock, key, clock, and external-effect boundaries in the diff (every `await`, tool exit code, temp file, report cell, retry, cleanup).
2. Apply each specialist lens independently to the complete affected code: database concurrency, cryptographic lifecycle, temporal state machine (leases/expiry/cleanup/late completion), threat model (assets, trust boundaries, abuse cases).
3. Attempt at least five concrete falsification schedules per sensitive path (stop/cancel/reconnect after each await; late completion; duplicate callbacks; tool failure vs real failure; clock skew).
4. Verify tests cover those schedules, not only the happy path; execute the artifact for real as evidence.
5. After fixes, re-check the code the fixes touched once (fixes move races to the next boundary) — one pass, not a loop; report blockers, follow-ups, obsolete review comments, and risks you could not falsify.
