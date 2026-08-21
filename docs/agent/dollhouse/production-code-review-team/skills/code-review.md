---
name: "Code Review"
description: "Systematic code analysis for quality, security, and best practices"
type: "skill"
version: "2.0.0"
author: "DollhouseMCP"
created: "2025-07-23"
category: "development"
tags: ["code-quality", "security", "best-practices", "review"]
---
# Code Review Skill

This skill provides systematic code analysis capabilities for identifying issues, suggesting improvements, and ensuring code quality.

## Core Capabilities

### 1. Security Analysis
- SQL injection vulnerabilities
- XSS and CSRF risks
- Authentication/authorization flaws
- Sensitive data exposure
- Dependency vulnerabilities

### 2. Code Quality
- SOLID principles adherence
- Design pattern usage
- Code duplication detection
- Complexity analysis
- Naming conventions

### 3. Performance Review
- Algorithm efficiency
- Database query optimization
- Memory usage patterns
- Caching opportunities
- Async/await patterns

### 4. Best Practices
- Error handling patterns
- Logging practices
- Documentation completeness
- Test coverage analysis
- Configuration management

### 5. Production Correctness
- Transaction and lock interleavings
- Async state-machine and lease boundaries
- Independent and simultaneous key rotation
- Database migration and PostgreSQL NULL semantics
- Multi-replica ordering and application/database clock skew
- Cleanup, retry, replay, and partial-failure behavior

## Review Process

### Step 1: Initial Scan
Quick overview identifying:
- Language and framework
- Project structure
- Key dependencies
- Test presence

### Step 2: Deep Analysis
Detailed examination of:
- Critical paths
- Security boundaries
- Data flow
- Error scenarios

For database, authentication, authorization, credential, migration, or
cryptographic changes, also activate and apply:
- Database Concurrency Review
- Cryptographic Lifecycle Review
- Temporal State Machine Review

### Step 3: Adversarial Falsification
Before recommending approval:

1. Write the protected claim in both directions, such as "unchanged credentials
   preserve connections" and "changed credentials revoke connections."
2. Build a matrix of independent configuration/key changes and simultaneous
   changes. Never assume two keys rotate together.
3. Mark every transaction boundary, `await`, external call, retry, and cleanup
   sweep. Insert a concurrent mutation or deadline crossing at each boundary.
4. Check final writes against current authoritative state and time. A previously
   captured snapshot or timestamp is not proof that a later write is valid.
5. Enumerate at least five concrete failure schedules for a security-sensitive
   change and explain why each is prevented. If one cannot be disproved, report
   it rather than approving.
6. Compare migrations against real legacy states, PostgreSQL three-valued logic,
   mixed-version rollout, reruns, and current effective authority.

### Step 4: Recommendations
Prioritized suggestions for:
- Critical fixes (security/bugs)
- Important improvements
- Nice-to-have enhancements
- Future considerations

## Output Format

Reviews are structured as:
1. **Executive Summary** - High-level findings
2. **Critical Issues** - Must-fix problems
3. **Recommendations** - Suggested improvements
4. **Positive Findings** - What's done well
5. **Metrics** - Code quality scores
6. **Boundary Inventory** - Transactions, locks, keys, clocks, and external effects
7. **Adversarial Schedules** - Attempted failure interleavings and outcomes
8. **Residual Risk** - Explicit uncertainty; never silently convert uncertainty into approval

## Approval Standard

- Do not approve merely because focused tests are green or because a prior
  reviewer found no issue.
- Treat production-relevant P2 findings in authentication, authorization,
  credential routing, migrations, data deletion, and lease enforcement as
  blocking unless the operator explicitly defers them.
- Re-review the complete affected state machine after every fix. Do not inspect
  only the newest lines; fixes frequently move a race to the next boundary.
- Distinguish obsolete review threads from unresolved code behavior by tracing
  the current commit.

## Example Usage

When activated, this skill enhances the AI's ability to:
- Spot subtle bugs and vulnerabilities
- Suggest idiomatic improvements
- Identify performance bottlenecks
- Recommend testing strategies
- Ensure security best practices

## Integration Notes

This skill works well with:
- Debug Detective persona for deep debugging
- Technical Analyst persona for architecture review
- Security-focused agents for vulnerability scanning
- Documentation templates for review reports
