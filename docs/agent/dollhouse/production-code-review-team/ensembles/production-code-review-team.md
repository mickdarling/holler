---
name: "Production Code Review Team"
description: "Focused adversarial review ensemble for production authentication, database, cryptographic, and asynchronous code"
type: "ensemble"
version: "1.0.0"
author: "DollhouseMCP"
created: "2026-08-21"
category: "development"
tags: ["code-review", "production", "security", "concurrency", "cryptography", "state-machine"]
activation_strategy: "sequential"
conflict_resolution: "priority"
context_sharing: "full"
resource_limits:
  max_active_elements: 8
  max_memory_mb: 512
  max_execution_time_ms: 60000
elements:
  - element_name: "production-code-reviewer"
    element_type: "agent"
    role: "primary"
    priority: 100
    activation: "always"
    purpose: "Coordinate the review, severity, evidence, and final verdict"

  - element_name: "code-review"
    element_type: "skill"
    role: "core"
    priority: 99
    activation: "always"
    purpose: "Apply the complete review and adversarial falsification process"

  - element_name: "database-concurrency-review"
    element_type: "skill"
    role: "core"
    priority: 98
    activation: "always"
    purpose: "Challenge transactions, locks, migrations, races, and replicas"

  - element_name: "cryptographic-lifecycle-review"
    element_type: "skill"
    role: "core"
    priority: 98
    activation: "always"
    purpose: "Challenge key separation, rotation, rewrap, and secret revisions"

  - element_name: "temporal-state-machine-review"
    element_type: "skill"
    role: "core"
    priority: 98
    activation: "always"
    purpose: "Challenge leases, expiry, cleanup, retry, and late completion"

  - element_name: "threat-modeling"
    element_type: "skill"
    role: "support"
    priority: 90
    activation: "always"
    purpose: "Map assets, trust boundaries, attackers, and abuse cases"

  - element_name: "security-analyst"
    element_type: "persona"
    role: "monitor"
    priority: 85
    activation: "always"
    purpose: "Keep security impact and exploitability central to severity"

  - element_name: "technical-analyst"
    element_type: "persona"
    role: "support"
    priority: 80
    activation: "always"
    purpose: "Check architecture, contracts, maintainability, and user-visible behavior"
---

# Production Code Review Team

Use this ensemble for changes that can alter production authority, credentials,
stored state, migrations, callbacks, leases, deletion, or cross-replica
behavior. It deliberately separates specialist failure models so a broad
reviewer cannot declare success after only a conventional static scan.

## Required Workflow

1. Inventory trust, transaction, lock, key, clock, and external-effect boundaries.
2. Apply each specialist independently to the complete affected state machine.
3. Attempt at least five concrete falsification schedules for every sensitive path.
4. Verify focused tests cover the schedules, not merely the happy path.
5. Re-run the complete review after fixes and report residual uncertainty.

The final report must distinguish confirmed blockers, non-blocking follow-ups,
obsolete review comments, and risks that could not be falsified.
