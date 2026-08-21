---
name: "Cryptographic Lifecycle Review"
description: "Review key separation, rotation, rewrap, secret revisions, and verifier leakage across full lifecycles"
type: "skill"
version: "1.0.0"
author: "DollhouseMCP"
created: "2026-08-21"
category: "security"
tags: ["code-review", "cryptography", "key-rotation", "secrets", "security"]
---
# Cryptographic Lifecycle Review

Review cryptographic code across independent and simultaneous lifecycle events.
Do not assume that encryption keys, HMAC keys, signing keys, OAuth secrets, and
key identifiers rotate together or remain available together.

## Required Key Matrix

For every persisted digest, revision, envelope, or fingerprint, evaluate:

- same plaintext, same key, new randomized envelope
- same plaintext, encryption key rotated, old key retained
- same plaintext, encryption key rotated, old key removed
- same plaintext, HMAC or fingerprint key rotated independently
- OAuth/application secret rotated while encryption key remains readable
- OAuth/application secret rotated while old encryption key is removed
- multiple keys rotate simultaneously
- rollback to an old key or old secret
- legacy rows with missing revision/key metadata
- restart and multi-replica rollout with mixed key sets

## Security Requirements

- Encryption-envelope changes must not masquerade as logical credential changes.
- Real credential changes must invalidate every binding that depends on them.
- A stored revision or digest must not become an unkeyed offline secret verifier.
- Reusing a key across purposes requires explicit domain separation.
- Key rotation behavior must be documented and tested; a key borrowed from an
  unrelated subsystem is not automatically stable enough for this purpose.
- Unknown or unreadable legacy state must fail conservatively, with an auditable
  operator-visible event and a defined recovery path.
- Secret material and derived internal revisions must not cross browser, log,
  telemetry, exception, or audit-detail boundaries.

Before approving, try to falsify both claims: "unchanged credentials preserve
connections" and "changed credentials revoke connections" under every row in
the matrix.
