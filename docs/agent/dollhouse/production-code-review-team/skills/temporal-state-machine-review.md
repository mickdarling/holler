---
name: "Temporal State Machine Review"
description: "Review leases, deadlines, retries, cleanup, and asynchronous state transitions against authoritative time"
type: "skill"
version: "1.0.0"
author: "DollhouseMCP"
created: "2026-08-21"
category: "development"
tags: ["code-review", "state-machine", "leases", "timeouts", "concurrency"]
---
# Temporal State Machine Review

Model asynchronous workflows as explicit state machines with authoritative
transition times. Validate the state at the moment an effect is committed, not
only when work begins.

## Required Review

1. List states, transitions, terminal states, retries, and cleanup ownership.
2. Identify every deadline: issuance, authorization expiry, consumption,
   completion lease, retry delay, sweep threshold, and credential persistence.
3. Require final persistence to compare the deadline with authoritative current
   time, preferably the database clock inside the committing transaction.
   Comparing two old timestamps only proves historical ordering.
4. Check work that pauses at every `await`, network request, queue boundary,
   process suspension, and retry. Assume it resumes after its lease expires.
5. Ensure cleanup cannot delete state still required by legitimate in-flight
   work, while late work cannot succeed merely because cleanup has not run yet.
6. Verify exactly-once or idempotent terminal transitions and safe handling of
   duplicate callbacks, replay, crash recovery, and partial external success.

## Mandatory Timeline Tests

- consume one tick before expiry; finish before and after completion lease
- external exchange hangs beyond the lease, then succeeds
- cleanup runs during external work and immediately before final persistence
- process pauses and resumes after deadline without cleanup running
- duplicate completion races with rotation, revocation, or deletion
- application and database clocks disagree

A stale-time comparison on an authentication, authorization, credential, or
payment boundary is production-relevant even when labeled P2.
