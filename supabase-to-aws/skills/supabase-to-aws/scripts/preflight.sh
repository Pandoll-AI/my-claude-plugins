#!/usr/bin/env bash
set -euo pipefail

echo "=== PREFLIGHT CHECK ==="
echo ""
PASS=0; FAIL=0; WARN=0

check() {
  local label="$1" cmd="$2" required="${3:-true}"
  if eval "$cmd" &>/dev/null; then
    echo "✅ $label"
    PASS=$((PASS + 1))
  elif [ "$required" = "true" ]; then
    echo "❌ $label"
    FAIL=$((FAIL + 1))
  else
    echo "⚠️  $label (optional)"
    WARN=$((WARN + 1))
  fi
}

# Tools
check "pg_dump installed" "command -v pg_dump"
check "psql installed" "command -v psql"
check "aws CLI installed" "command -v aws"
check "node installed" "command -v node"
check "npx installed" "command -v npx" false

# AWS credentials
check "AWS credentials configured" "aws sts get-caller-identity"

# Source DB
if [ -n "${SUPABASE_DB_URL:-}" ]; then
  check "Supabase DB reachable" "psql '$SUPABASE_DB_URL' -c 'SELECT 1' -t"
else
  echo "❌ SUPABASE_DB_URL not set"
  FAIL=$((FAIL + 1))
fi

# Target DB
if [ -n "${AWS_RDS_URL:-}" ]; then
  check "AWS RDS reachable" "psql '$AWS_RDS_URL' -c 'SELECT 1' -t"
else
  echo "⚠️  AWS_RDS_URL not set (run aws-bootstrap.sh first)"
  WARN=$((WARN + 1))
fi

# PG version compatibility
if [ -n "${SUPABASE_DB_URL:-}" ]; then
  SRC_VER=$(psql "$SUPABASE_DB_URL" -t -A -c "SHOW server_version_num;" 2>/dev/null || echo "unknown")
  DUMP_VER=$(pg_dump --version 2>/dev/null | grep -oP '\d+' | head -1 || echo "unknown")
  echo "ℹ️  Source PG version: $SRC_VER, pg_dump major: $DUMP_VER"
  if [ "$DUMP_VER" != "unknown" ] && [ "$SRC_VER" != "unknown" ]; then
    SRC_MAJOR=$(echo "$SRC_VER" | cut -c1-2)
    if [ "$DUMP_VER" -lt "$SRC_MAJOR" ]; then
      echo "⚠️  pg_dump ($DUMP_VER) older than source ($SRC_MAJOR) — upgrade recommended"
      WARN=$((WARN + 1))
    fi
  fi
fi

echo ""
echo "=== RESULT ==="
echo "✅ Passed: $PASS"
echo "❌ Failed: $FAIL"
echo "⚠️  Warnings: $WARN"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Fix failed checks before proceeding."
  exit 1
fi
