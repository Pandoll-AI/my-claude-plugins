---
description: "Install or update Supabase→AWS portability rules for the current project"
argument-hint: "[prototype|production]"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Database Portability Guard

Read the skill at `skills/supabase-to-aws/SKILL.md`, then execute **Mode 2: GUARD**.

1. Copy `skills/supabase-to-aws/references/db-portability-rules.md` into the project's `.claude/rules/` directory.
2. Set `DB_PHASE` in `.env` to `$ARGUMENTS` (default: `prototype`).
3. Confirm to the user what phase they're in and summarize the active rules.
4. If phase is `production`, run a quick audit first to show current violations.
