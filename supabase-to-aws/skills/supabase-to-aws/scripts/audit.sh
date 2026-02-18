#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:-.}"
REPORT_FILE="${2:-migration-readiness.md}"

echo "🔍 Scanning: $PROJECT_ROOT"
echo ""

# Counters
SDK_COUNT=0; DATA_COUNT=0; REST_COUNT=0; STORAGE_COUNT=0; RLS_COUNT=0
DRIZZLE_COUNT=0; PRISMA_COUNT=0; PROTO_COUNT=0; VIOLATION_COUNT=0

# Helper: count grep matches safely
count_matches() {
  local result
  result=$(eval "$1" 2>/dev/null | grep -c "." 2>/dev/null) || result=0
  echo "$result"
}

# Helper: capture grep output safely
capture_matches() {
  eval "$1" 2>/dev/null || true
}

EXCLUDE="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist --exclude-dir=build --exclude-dir=.git"
TS_FILES='--include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx"'

# 1. SDK imports
SDK_CMD="grep -rn \"from ['\\\"]@supabase\" $TS_FILES $EXCLUDE \"$PROJECT_ROOT\""
SDK_COUNT=$(count_matches "$SDK_CMD")
SDK_QUARANTINED=$(capture_matches "$SDK_CMD" | grep -c "lib/auth/\|lib/storage/\|lib/realtime/" 2>/dev/null || echo 0)
SDK_LEAKED=$((SDK_COUNT - SDK_QUARANTINED))

# 2. Data queries
DATA_CMD="grep -rn 'supabase\.\(from\|rpc\)' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\""
DATA_COUNT=$(count_matches "$DATA_CMD")

# 3. PostgREST
REST_CMD="grep -rn '/rest/v1/' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\""
REST_COUNT=$(count_matches "$REST_CMD")

# 4. Hardcoded storage URLs
STORAGE_CMD="grep -rn 'supabase\.co/storage' $TS_FILES --include=\"*.sql\" $EXCLUDE \"$PROJECT_ROOT\""
STORAGE_COUNT=$(count_matches "$STORAGE_CMD")

# 5. RLS dependencies
RLS_CMD="grep -rn 'auth\.uid\|auth\.role\|auth\.jwt\|ENABLE ROW LEVEL' --include=\"*.sql\" $EXCLUDE \"$PROJECT_ROOT\""
RLS_COUNT=$(count_matches "$RLS_CMD")

# 6. ORM (positive)
DRIZZLE_COUNT=$(count_matches "grep -rn 'drizzle' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\"")
PRISMA_COUNT=$(count_matches "grep -rn '@prisma' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\"")

# 7. Abstractions
AUTH_ABS=false; STORAGE_ABS=false; DB_ABS=false
[ -d "$PROJECT_ROOT/lib/auth" ] || [ -d "$PROJECT_ROOT/src/lib/auth" ] && AUTH_ABS=true
[ -d "$PROJECT_ROOT/lib/storage" ] || [ -d "$PROJECT_ROOT/src/lib/storage" ] && STORAGE_ABS=true
[ -d "$PROJECT_ROOT/lib/db" ] || [ -d "$PROJECT_ROOT/src/lib/db" ] && DB_ABS=true

# 8. Markers
PROTO_COUNT=$(count_matches "grep -rn 'PROTOTYPE_ONLY' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\"")
VIOLATION_COUNT=$(count_matches "grep -rn 'DB_PORTABILITY_VIOLATION' $TS_FILES $EXCLUDE \"$PROJECT_ROOT\"")

# 9. Migration infra
HAS_MIGRATIONS=false
HAS_DRIZZLE_CONFIG=false
[ -n "$(find "$PROJECT_ROOT" -type d -name migrations -not -path '*/node_modules/*' 2>/dev/null)" ] && HAS_MIGRATIONS=true
[ -n "$(find "$PROJECT_ROOT" -name 'drizzle.config.*' -not -path '*/node_modules/*' 2>/dev/null)" ] && HAS_DRIZZLE_CONFIG=true

# 10. DATABASE_URL check
HAS_DB_URL=false
grep -q "DATABASE_URL" "$PROJECT_ROOT"/.env* 2>/dev/null && HAS_DB_URL=true

# Score
TOTAL_VIOLATIONS=$((DATA_COUNT + REST_COUNT + STORAGE_COUNT + SDK_LEAKED))

if [ "$TOTAL_VIOLATIONS" -eq 0 ] && [ "$DRIZZLE_COUNT" -gt 0 ]; then
  SCORE="🟢 READY"
  EFFORT="None — ready to migrate"
elif [ "$TOTAL_VIOLATIONS" -lt 10 ]; then
  SCORE="🟡 LOW COUPLING"
  EFFORT="< 4 hours refactor"
elif [ "$TOTAL_VIOLATIONS" -lt 50 ]; then
  SCORE="🟠 MODERATE COUPLING"
  EFFORT="1-2 days refactor"
else
  SCORE="🔴 HIGH COUPLING"
  EFFORT="3+ days refactor"
fi

# ORM detection
if [ "$DRIZZLE_COUNT" -gt 0 ]; then ORM="Drizzle"
elif [ "$PRISMA_COUNT" -gt 0 ]; then ORM="Prisma"
else ORM="None (Supabase SDK only)"
fi

# Generate report
cat > "$REPORT_FILE" << EOF
# Migration Readiness Report

Generated: $(date -u +"%Y-%m-%d %H:%M UTC")
Project: $PROJECT_ROOT

## Score: $SCORE

## Metrics

| Category | Count | Status |
|----------|-------|--------|
| Supabase SDK imports (total) | $SDK_COUNT | $([ "$SDK_COUNT" -eq 0 ] && echo "✅" || echo "ℹ️") |
| SDK imports outside quarantine | $SDK_LEAKED | $([ "$SDK_LEAKED" -eq 0 ] && echo "✅" || echo "❌ blocking") |
| Data queries via Supabase SDK | $DATA_COUNT | $([ "$DATA_COUNT" -eq 0 ] && echo "✅" || echo "❌ blocking") |
| Direct PostgREST calls | $REST_COUNT | $([ "$REST_COUNT" -eq 0 ] && echo "✅" || echo "❌ blocking") |
| Hardcoded storage URLs | $STORAGE_COUNT | $([ "$STORAGE_COUNT" -eq 0 ] && echo "✅" || echo "⚠️ non-blocking") |
| RLS policy references | $RLS_COUNT | $([ "$RLS_COUNT" -eq 0 ] && echo "✅" || echo "⚠️ non-blocking") |
| ORM references | $((DRIZZLE_COUNT + PRISMA_COUNT)) | $([ "$((DRIZZLE_COUNT + PRISMA_COUNT))" -gt 0 ] && echo "✅" || echo "❌") |
| PROTOTYPE_ONLY markers | $PROTO_COUNT | ℹ️ |
| VIOLATION markers | $VIOLATION_COUNT | ℹ️ |

## Current Architecture

- **ORM:** $ORM
- **Auth abstraction:** $AUTH_ABS
- **Storage abstraction:** $STORAGE_ABS
- **DB abstraction:** $DB_ABS
- **DATABASE_URL env:** $HAS_DB_URL
- **Migration files:** $HAS_MIGRATIONS
- **Drizzle config:** $HAS_DRIZZLE_CONFIG

## Blocking Issues (fix before migration)

$([ "$SDK_LEAKED" -gt 0 ] && echo "- ❌ $SDK_LEAKED Supabase SDK imports outside quarantine zones" || true)
$([ "$DATA_COUNT" -gt 0 ] && echo "- ❌ $DATA_COUNT data queries via Supabase SDK (need ORM conversion)" || true)
$([ "$REST_COUNT" -gt 0 ] && echo "- ❌ $REST_COUNT direct PostgREST calls (need API route conversion)" || true)
$([ "$DRIZZLE_COUNT" -eq 0 ] && [ "$PRISMA_COUNT" -eq 0 ] && echo "- ❌ No ORM detected (install Drizzle ORM)" || true)
$([ "$HAS_DB_URL" = false ] && echo "- ❌ No DATABASE_URL in env files" || true)
$([ "$TOTAL_VIOLATIONS" -eq 0 ] && echo "None 🎉" || true)

## Non-Blocking Issues (fix during or after migration)

$([ "$STORAGE_COUNT" -gt 0 ] && echo "- ⚠️ $STORAGE_COUNT hardcoded Supabase Storage URLs in code/DB" || true)
$([ "$RLS_COUNT" -gt 0 ] && echo "- ⚠️ $RLS_COUNT RLS references (ensure app-level auth exists)" || true)
$([ "$AUTH_ABS" = false ] && echo "- ⚠️ No auth abstraction layer (create lib/auth/)" || true)
$([ "$STORAGE_ABS" = false ] && echo "- ⚠️ No storage abstraction layer (create lib/storage/)" || true)

## Estimated Effort

$EFFORT

## Recommended Next Step

$(if [ "$TOTAL_VIOLATIONS" -eq 0 ] && [ "$DRIZZLE_COUNT" -gt 0 ]; then
  echo "Run **MIGRATE** mode — your codebase is ready."
elif [ "$TOTAL_VIOLATIONS" -lt 10 ]; then
  echo "Install **GUARD** rules (production phase), refactor $TOTAL_VIOLATIONS violation(s), then migrate."
else
  echo "Install **GUARD** rules, run systematic refactor. Consider starting with the highest-violation files."
fi)
EOF

echo "✅ Report saved: $REPORT_FILE"
echo ""
echo "=== SUMMARY ==="
echo "Score: $SCORE"
echo "Blocking violations: $((DATA_COUNT + REST_COUNT + SDK_LEAKED))"
echo "Non-blocking issues: $((STORAGE_COUNT + RLS_COUNT))"
echo "Estimated effort: $EFFORT"
