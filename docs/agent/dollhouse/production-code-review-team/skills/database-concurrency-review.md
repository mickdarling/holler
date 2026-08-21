---
name: "Database Concurrency Review"
description: "Adversarial review of transactions, locks, races, migrations, and cross-replica ordering"
type: "skill"
version: "1.0.0"
author: "DollhouseMCP"
created: "2026-08-21"
category: "development"
tags: ["code-review", "database", "concurrency", "postgresql", "security"]
---
# Database Concurrency Review

Review database-backed behavior as an adversarial schedule, not as a single
thread. A green happy path is not sufficient evidence of correctness.

## Required Analysis

1. Identify every read, lock, write, commit, external call, retry, and cleanup
   operation on the reviewed path.
2. Enumerate interleavings where another request, worker, deployment replica,
   or cleanup job mutates the same authority or credential between those steps.
3. Verify that the security decision and its effect share a transaction,
   version check, compare-and-swap, or compatible lock. A second read before an
   external call is not atomic protection for a later write.
4. Check lock scope and ordering. A row lock cannot serialize an identity or
   object that has no row yet. Sequence allocation orders allocation, not
   transaction commit.
5. Review PostgreSQL behavior explicitly: READ COMMITTED snapshots, three-valued
   CHECK logic, NULL semantics, foreign keys, isolation, advisory locks,
   deadlocks, and database-clock versus application-clock ordering.
   Distinguish `NOW()`/`transaction_timestamp()` (fixed at transaction start),
   `statement_timestamp()` (fixed per statement), and `clock_timestamp()`
   (wall clock). A repeated `NOW()` predicate in one transaction is not a fresh
   deadline check.
6. For migrations, preserve the database's current effective state, not a
   reconstructed history based on possibly skewed timestamps. Test legacy,
   partially migrated, rerun, empty-table, and live-data cases.

## Mandatory Race Matrix

For each protected operation, test or reason through:

- read old state -> concurrent rotation/deletion -> stale external effect
- authorization passes -> concurrent revocation -> account/credential write
- consume lease -> slow or suspended work -> cleanup sweep -> late completion
- no row exists -> concurrent create/delete -> insert after security decision
- replica A allocates order -> replica B commits later/earlier
- transaction succeeds but audit/event write fails, and the reverse

Report any path that can persist stale authority, credentials, tokens, or audit
data as at least P2 and raise it to P1 when exploitation is practical or the
affected boundary is authentication, authorization, or secret routing.
