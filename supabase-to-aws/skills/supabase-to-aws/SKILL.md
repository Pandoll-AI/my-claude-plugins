---
name: supabase-to-aws
description: |
  Full-lifecycle database portability plugin for Supabase ↔ AWS. Handles three modes:
  1. AUDIT — Assess any existing codebase's Supabase coupling level and generate a migration readiness report
  2. GUARD — Enforce portability rules during development (prototype vs production phase)
  3. MIGRATE — Execute the actual Supabase → AWS migration (Auth → Storage → Database)
  Use when: user mentions Supabase migration, database portability, switching to AWS, or asks to audit Supabase coupling.
---

# Supabase ↔ AWS Portability Plugin

## Quick Start

This plugin has 3 modes. Determine which mode to use:

| User says | Mode | Action |
|-----------|------|--------|
| "Audit my project" / "How coupled am I to Supabase?" | **AUDIT** | Scan codebase → generate readiness report |
| "Start a new project" / "Apply portability rules" | **GUARD** | Install rules → enforce during development |
| "Migrate to AWS" / "I'm ready to switch" | **MIGRATE** | Run services-first migration |

If unsure, **always start with AUDIT**. It takes 30 seconds and tells you exactly where you stand.

---

## Mode 1: AUDIT

### Purpose
Assess ANY codebase at ANY stage — greenfield, prototype, production, legacy — and produce a migration readiness score.

### Step 1.1 — Run the audit script

```bash
bash "$(dirname "$0")/scripts/audit.sh" .
```

If the script is not executable or available, run the audit inline:

```bash
PROJECT_ROOT="${1:-.}"

echo "=== SUPABASE COUPLING AUDIT ==="
echo ""

# 1. Detect Supabase SDK usage
echo "## 1. Supabase SDK Imports"
SDK_HITS=$(grep -rn "from ['\"]@supabase" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  "$PROJECT_ROOT" --exclude-dir=node_modules --exclude-dir=.next 2>/dev/null)
SDK_COUNT=$(echo "$SDK_HITS" | grep -c "." 2>/dev/null || echo 0)
echo "Total imports: $SDK_COUNT"
echo "$SDK_HITS"
echo ""

# 2. Detect data queries via Supabase SDK
echo "## 2. Supabase Data Queries (coupling hotspots)"
DATA_HITS=$(grep -rn "supabase\.\(from\|rpc\)" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  "$PROJECT_ROOT" --exclude-dir=node_modules --exclude-dir=.next 2>/dev/null)
DATA_COUNT=$(echo "$DATA_HITS" | grep -c "." 2>/dev/null || echo 0)
echo "Data query calls: $DATA_COUNT"
echo "$DATA_HITS"
echo ""

# 3. Detect PostgREST direct calls
echo "## 3. Direct PostgREST / REST API Calls"
REST_HITS=$(grep -rn "/rest/v1/\|\.supabase\.co" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  "$PROJECT_ROOT" --exclude-dir=node_modules --exclude-dir=.next 2>/dev/null)
REST_COUNT=$(echo "$REST_HITS" | grep -c "." 2>/dev/null || echo 0)
echo "Direct REST calls: $REST_COUNT"
echo ""

# 4. Detect hardcoded storage URLs
echo "## 4. Hardcoded Supabase Storage URLs"
STORAGE_HITS=$(grep -rn "supabase\.co/storage" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.sql" \
  "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null)
STORAGE_COUNT=$(echo "$STORAGE_HITS" | grep -c "." 2>/dev/null || echo 0)
echo "Hardcoded URLs: $STORAGE_COUNT"
echo ""

# 5. Detect RLS-only auth
echo "## 5. RLS Policy Dependencies"
RLS_HITS=$(grep -rn "auth\.uid\|auth\.role\|auth\.jwt\|ENABLE ROW LEVEL" \
  --include="*.sql" \
  "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null)
RLS_COUNT=$(echo "$RLS_HITS" | grep -c "." 2>/dev/null || echo 0)
echo "RLS references: $RLS_COUNT"
echo ""

# 6. Detect ORM usage (positive signal)
echo "## 6. ORM/Abstraction Layer (positive signals)"
DRIZZLE=$(grep -rn "drizzle\|from 'drizzle" --include="*.ts" --include="*.js" "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null | grep -c "." || echo 0)
PRISMA=$(grep -rn "prisma\|from '@prisma" --include="*.ts" --include="*.js" "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null | grep -c "." || echo 0)
echo "Drizzle references: $DRIZZLE"
echo "Prisma references: $PRISMA"
echo ""

# 7. Detect existing abstraction
echo "## 7. Existing Provider Abstractions"
for dir in lib/auth lib/storage lib/realtime lib/db src/lib/auth src/lib/storage src/lib/db; do
  if [ -d "$PROJECT_ROOT/$dir" ]; then
    echo "✅ Found: $dir/"
  fi
done
echo ""

# 8. Detect env var patterns
echo "## 8. Environment Configuration"
if [ -f "$PROJECT_ROOT/.env.example" ] || [ -f "$PROJECT_ROOT/.env.local" ] || [ -f "$PROJECT_ROOT/.env" ]; then
  grep -h "DATABASE_URL\|SUPABASE\|AUTH_PROVIDER\|STORAGE_PROVIDER\|DB_PHASE" \
    "$PROJECT_ROOT"/.env* 2>/dev/null | sed 's/=.*/=***/' || true
fi
echo ""

# 9. Detect existing markers
echo "## 9. Portability Markers"
PROTO=$(grep -rn "PROTOTYPE_ONLY" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null | grep -c "." || echo 0)
VIOLATION=$(grep -rn "DB_PORTABILITY_VIOLATION" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" "$PROJECT_ROOT" --exclude-dir=node_modules 2>/dev/null | grep -c "." || echo 0)
echo "PROTOTYPE_ONLY markers: $PROTO"
echo "DB_PORTABILITY_VIOLATION markers: $VIOLATION"
echo ""

# 10. Migration files
echo "## 10. Migration Infrastructure"
MIGRATION_DIRS=$(find "$PROJECT_ROOT" -type d -name "migrations" -not -path "*/node_modules/*" 2>/dev/null)
DRIZZLE_CONFIG=$(find "$PROJECT_ROOT" -name "drizzle.config.*" -not -path "*/node_modules/*" 2>/dev/null)
echo "Migration dirs: ${MIGRATION_DIRS:-none}"
echo "Drizzle config: ${DRIZZLE_CONFIG:-none}"
echo ""

# Summary
echo "========================================="
echo "READINESS SCORE"
echo "========================================="
TOTAL_VIOLATIONS=$((DATA_COUNT + REST_COUNT + STORAGE_COUNT))
if [ "$TOTAL_VIOLATIONS" -eq 0 ] && [ "$DRIZZLE" -gt 0 ]; then
  echo "🟢 READY — No Supabase data coupling detected, ORM in use"
elif [ "$TOTAL_VIOLATIONS" -lt 10 ]; then
  echo "🟡 LOW COUPLING — $TOTAL_VIOLATIONS violation(s), manageable refactor"
elif [ "$TOTAL_VIOLATIONS" -lt 50 ]; then
  echo "🟠 MODERATE COUPLING — $TOTAL_VIOLATIONS violations, plan 1-2 days refactor"
else
  echo "🔴 HIGH COUPLING — $TOTAL_VIOLATIONS violations, significant refactor needed"
fi
```

### Step 1.2 — Generate readiness report

After running the audit, produce a `migration-readiness.md` report:

```markdown
# Migration Readiness Report
Generated: [date]

## Score: [🟢🟡🟠🔴] [READY/LOW/MODERATE/HIGH]

## Current State
- ORM: [Drizzle/Prisma/None/Supabase SDK]
- Auth: [GoTrue via abstraction / GoTrue direct / None]
- Storage: [Abstracted / Direct URLs / None]
- DB Connection: [DATABASE_URL abstracted / Hardcoded / Mixed]

## Blocking Issues (must fix before migration)
1. [list]

## Non-Blocking Issues (can fix post-migration)
1. [list]

## Recommended Action
- [Install GUARD rules and refactor / Ready to MIGRATE / etc.]

## Estimated Effort
- Refactor: [hours/days]
- Migration execution: [hours]
- Validation: [hours]
```

---

## Mode 2: GUARD

### Purpose
Enforce portability rules during active development. Two sub-phases.

### Step 2.1 — Install rules file

Copy `references/db-portability-rules.md` to the project's `.claude/rules/` directory:

```bash
mkdir -p .claude/rules
cp "$(dirname "$0")/references/db-portability-rules.md" .claude/rules/db-portability.md
```

### Step 2.2 — Set phase

Ask the user:

> Are you in prototype (speed-first, rules relaxed) or production (portability enforced)?

Set `DB_PHASE` in `.env`:
- `prototype` → Supabase SDK allowed everywhere, but `PROTOTYPE_ONLY` markers required
- `production` → Full rules enforced, violation procedure active

### Step 2.3 — Phase transition

When the user says "switch to production":

1. Run AUDIT (Mode 1) to find all `PROTOTYPE_ONLY` markers and violations
2. Generate a refactor checklist as `refactor-plan.md`
3. Offer to auto-refactor each file (replace `.from()` with Drizzle, add abstractions)
4. Re-run AUDIT to confirm 🟢

See `references/db-portability-rules.md` for the full rule set.

---

## Mode 3: MIGRATE

### Prerequisites Check

Before any migration step, run this checklist:

```bash
bash "$(dirname "$0")/scripts/preflight.sh"
```

The preflight checks:
- [ ] Required CLI tools installed (`pg_dump`, `psql`, `aws`, `node`)
- [ ] Source DB accessible (`SUPABASE_DB_URL`)
- [ ] Target DB accessible (`AWS_RDS_URL`) — or needs AWS bootstrap
- [ ] AWS credentials configured (`aws sts get-caller-identity`)
- [ ] Audit score is 🟢 or 🟡 (if 🟠/🔴, must refactor first)

### Step 3.0 — AWS Bootstrap (if no AWS infrastructure exists)

**Goal: user provides ONLY `AWS_REGION` and a `PROJECT_NAME`. Everything else is automated.**

```bash
bash "$(dirname "$0")/scripts/aws-bootstrap.sh" <project-name> <region>
```

This script:
1. Creates a CloudFormation stack using `templates/aws-stack.yaml`
2. Provisions: RDS PostgreSQL (db.t4g.micro, free tier), Cognito User Pool, S3 Bucket
3. Outputs connection strings and ARNs
4. Writes them to `.env.aws` for the user to merge

If the user already has AWS infrastructure, skip to Step 3.1.

See `templates/aws-stack.yaml` for the CloudFormation template.

### Step 3.1 — Auth Migration (GoTrue → Cognito)

Read `references/migration-playbook.md#auth` for full procedure.

Summary:
1. Export users from `auth.users`
2. Create Cognito User Pool (or use bootstrap output)
3. Bulk import users (passwords require reset or migration Lambda)
4. Swap `lib/auth/` implementation
5. **Checkpoint:** Verify `AUTH_PROVIDER=cognito` works with app login flow

### Step 3.2 — Storage Migration (Supabase Storage → S3)

Read `references/migration-playbook.md#storage` for full procedure.

Summary:
1. List all buckets and objects
2. Download via S3-compatible API or Supabase CLI
3. Upload to S3 bucket
4. Fix any leaked full URLs in database
5. Swap `lib/storage/` implementation
6. **Checkpoint:** Verify file upload/download works

### Step 3.3 — Database Migration (Supabase Postgres → RDS)

Read `references/migration-playbook.md#database` for full procedure.

Summary:
1. Export `public` schema only (strip Supabase roles, RLS)
2. Restore schema to RDS
3. Set source read-only → export data → restore data
4. Sync sequences (CRITICAL)
5. **Checkpoint:** Row count comparison

### Step 3.4 — Validation

Run the full validation suite:

```bash
bash "$(dirname "$0")/scripts/validate.sh"
```

This checks:
- [ ] Row counts match between source and target
- [ ] Sequences are synced (next INSERT won't collide)
- [ ] All Postgres extensions are available on RDS
- [ ] Application test suite passes against RDS
- [ ] Auth flow works end-to-end
- [ ] Storage upload/download works

### Step 3.5 — Cutover Checklist

Interactive checklist — confirm each item with the user:

- [ ] All validation checks passed
- [ ] `.env` updated: `DATABASE_URL`, `AUTH_PROVIDER`, `STORAGE_PROVIDER`
- [ ] CI/CD pipelines updated
- [ ] DNS/API endpoints updated if applicable
- [ ] Monitoring/alerting configured for RDS
- [ ] Supabase project kept alive for rollback (recommend 14 days)
- [ ] Team notified of migration window
- [ ] Rollback plan documented and tested

### Rollback

Each phase is independently reversible:

| Phase | Rollback |
|-------|----------|
| Auth | Revert `lib/auth/` to GoTrue, set `AUTH_PROVIDER=supabase` |
| Storage | Revert `lib/storage/`, set `STORAGE_PROVIDER=supabase` |
| Database | Set `DATABASE_URL` back to Supabase, re-enable writes |

---

## File Reference

```
supabase-to-aws/
├── SKILL.md                              ← You are here
├── references/
│   ├── db-portability-rules.md           ← GUARD mode rules (install to .claude/rules/)
│   ├── migration-playbook.md             ← Detailed step-by-step procedures
│   └── checklist.md                      ← All checklists in one place
├── scripts/
│   ├── audit.sh                          ← Codebase coupling scanner
│   ├── preflight.sh                      ← Pre-migration prerequisites check
│   ├── aws-bootstrap.sh                  ← One-command AWS infrastructure setup
│   ├── migrate-auth.sh                   ← Auth migration automation
│   ├── migrate-storage.sh                ← Storage migration automation
│   ├── migrate-db.sh                     ← Database migration automation
│   └── validate.sh                       ← Post-migration validation suite
└── templates/
    └── aws-stack.yaml                    ← CloudFormation template (RDS + Cognito + S3)
```
