#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Post-Migration Validation
# Compares Supabase (source) vs RDS (target)
# Usage: ./validate.sh
# Requires: SUPABASE_DB_URL, AWS_RDS_URL env vars
# ============================================================

SRC="${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
TGT="${AWS_RDS_URL:?Set AWS_RDS_URL}"

PASS=0; FAIL=0; WARN=0
REPORT="validation-report.md"

ok()   { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

echo "=== POST-MIGRATION VALIDATION ==="
echo ""

# ── 1. Connectivity ──
echo "## 1. Connectivity"
psql "$SRC" -c "SELECT 1" -t &>/dev/null && ok "Source (Supabase) reachable" || fail "Source unreachable"
psql "$TGT" -c "SELECT 1" -t &>/dev/null && ok "Target (RDS) reachable" || fail "Target unreachable"
echo ""

# ── 2. Table comparison ──
echo "## 2. Table Existence"
SRC_TABLES=$(psql "$SRC" -t -A -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;")
TGT_TABLES=$(psql "$TGT" -t -A -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;")

SRC_COUNT=$(echo "$SRC_TABLES" | grep -c "." || echo 0)
TGT_COUNT=$(echo "$TGT_TABLES" | grep -c "." || echo 0)

if [ "$SRC_COUNT" -eq "$TGT_COUNT" ]; then
  ok "Table count matches: $SRC_COUNT"
else
  fail "Table count mismatch: source=$SRC_COUNT, target=$TGT_COUNT"
fi

# Find missing tables
MISSING=$(comm -23 <(echo "$SRC_TABLES" | sort) <(echo "$TGT_TABLES" | sort))
if [ -n "$MISSING" ]; then
  fail "Missing tables in target: $MISSING"
fi
echo ""

# ── 3. Row counts ──
echo "## 3. Row Counts"
ROW_MISMATCHES=""
while IFS= read -r table; do
  [ -z "$table" ] && continue
  SRC_ROWS=$(psql "$SRC" -t -A -c "SELECT count(*) FROM public.\"$table\";" 2>/dev/null || echo "ERROR")
  TGT_ROWS=$(psql "$TGT" -t -A -c "SELECT count(*) FROM public.\"$table\";" 2>/dev/null || echo "ERROR")
  
  if [ "$SRC_ROWS" = "$TGT_ROWS" ]; then
    ok "$table: $SRC_ROWS rows"
  else
    fail "$table: source=$SRC_ROWS, target=$TGT_ROWS"
    ROW_MISMATCHES="$ROW_MISMATCHES\n  - $table: source=$SRC_ROWS, target=$TGT_ROWS"
  fi
done <<< "$SRC_TABLES"
echo ""

# ── 4. Sequence sync ──
echo "## 4. Sequences"
SRC_SEQS=$(psql "$SRC" -t -A -c "
  SELECT sequencename || '=' || COALESCE(last_value::text, 'NULL')
  FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename;
" 2>/dev/null)
TGT_SEQS=$(psql "$TGT" -t -A -c "
  SELECT sequencename || '=' || COALESCE(last_value::text, 'NULL')
  FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename;
" 2>/dev/null)

SEQ_MISMATCHES=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  SEQ_NAME=$(echo "$line" | cut -d= -f1)
  SRC_VAL=$(echo "$line" | cut -d= -f2)
  TGT_VAL=$(echo "$TGT_SEQS" | grep "^${SEQ_NAME}=" | cut -d= -f2 || echo "MISSING")
  
  if [ "$SRC_VAL" = "$TGT_VAL" ]; then
    ok "$SEQ_NAME: $SRC_VAL"
  elif [ "$TGT_VAL" = "MISSING" ]; then
    fail "$SEQ_NAME: missing in target"
  else
    fail "$SEQ_NAME: source=$SRC_VAL, target=$TGT_VAL"
    SEQ_MISMATCHES="$SEQ_MISMATCHES\n  - $SEQ_NAME: source=$SRC_VAL, target=$TGT_VAL"
  fi
done <<< "$SRC_SEQS"
echo ""

# ── 5. Extensions ──
echo "## 5. Extensions"
SRC_EXTS=$(psql "$SRC" -t -A -c "SELECT extname FROM pg_extension WHERE extname NOT IN ('plpgsql') ORDER BY extname;" 2>/dev/null)
TGT_EXTS=$(psql "$TGT" -t -A -c "SELECT extname FROM pg_extension WHERE extname NOT IN ('plpgsql') ORDER BY extname;" 2>/dev/null)

while IFS= read -r ext; do
  [ -z "$ext" ] && continue
  if echo "$TGT_EXTS" | grep -q "^${ext}$"; then
    ok "Extension: $ext"
  else
    warn "Extension missing in target: $ext (may need manual install or alternative)"
  fi
done <<< "$SRC_EXTS"
echo ""

# ── 6. INSERT test (sequence verification) ──
echo "## 6. Write Test"
FIRST_TABLE=$(echo "$TGT_TABLES" | head -1)
if [ -n "$FIRST_TABLE" ]; then
  # Try a dry-run: begin + insert + rollback
  WRITE_TEST=$(psql "$TGT" -t -A -c "
    BEGIN;
    INSERT INTO public.\"$FIRST_TABLE\" DEFAULT VALUES;
    ROLLBACK;
    SELECT 'ok';
  " 2>&1)
  
  if echo "$WRITE_TEST" | grep -q "ok"; then
    ok "INSERT+ROLLBACK on $FIRST_TABLE succeeded (sequences working)"
  else
    warn "Write test on $FIRST_TABLE inconclusive (table may have NOT NULL constraints)"
  fi
fi
echo ""

# ── Summary ──
echo "========================================="
echo "VALIDATION RESULT"
echo "========================================="
echo "✅ Passed: $PASS"
echo "❌ Failed: $FAIL"
echo "⚠️  Warnings: $WARN"

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "🎉 All critical checks passed. Safe to proceed with cutover."
else
  echo ""
  echo "⛔ $FAIL critical issue(s) found. Fix before cutover."
fi

# ── Write report ──
cat > "$REPORT" << EOF
# Validation Report

Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

## Result: $([ "$FAIL" -eq 0 ] && echo "✅ PASS" || echo "❌ FAIL")

- Passed: $PASS
- Failed: $FAIL
- Warnings: $WARN

## Row Count Mismatches
$([ -n "$ROW_MISMATCHES" ] && echo -e "$ROW_MISMATCHES" || echo "None")

## Sequence Mismatches
$([ -n "$SEQ_MISMATCHES" ] && echo -e "$SEQ_MISMATCHES" || echo "None")
EOF

echo ""
echo "📄 Report saved: $REPORT"
