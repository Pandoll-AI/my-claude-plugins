---
description: "Scan codebase for Supabase coupling and generate a migration readiness report"
argument-hint: "[path-to-project]"
allowed-tools:
  - Bash
  - Read
  - Grep
  - Write
---

# Database Portability Audit

Read the skill at `skills/supabase-to-aws/SKILL.md`, then execute **Mode 1: AUDIT**.

1. Run `skills/supabase-to-aws/scripts/audit.sh` against the project at `$ARGUMENTS` (default: current directory).
2. Present the readiness score (🟢🟡🟠🔴) and key metrics.
3. List blocking issues vs non-blocking issues.
4. Recommend next action (GUARD rules or MIGRATE).
5. Save the full report as `migration-readiness.md` in the project root.
