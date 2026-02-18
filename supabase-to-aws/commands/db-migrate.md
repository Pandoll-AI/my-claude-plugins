---
description: "Execute Supabase → AWS migration (Auth → Storage → Database)"
argument-hint: "[auth|storage|database|all] [--dry-run]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
---

# Database Migration

Read the skill at `skills/supabase-to-aws/SKILL.md`, then execute **Mode 3: MIGRATE**.

## Workflow

1. Run `skills/supabase-to-aws/scripts/preflight.sh` to verify prerequisites.
2. Based on `$ARGUMENTS`:
   - `auth` → Run `migrate-auth.sh`
   - `storage` → Run `migrate-storage.sh`
   - `database` → Run `migrate-db.sh`
   - `all` → Run all three in order (auth → storage → database)
   - If `--dry-run` flag present, pass it to each script.
3. After each phase, run `validate.sh` and report results.
4. Present the migration checklist from `references/checklist.md` with current status.

## Safety

- Always confirm with the user before executing destructive operations.
- Default to `--dry-run` if user didn't specify.
- If any phase fails validation, stop and present rollback options.
