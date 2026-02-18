#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Database Migration: Supabase Postgres → AWS RDS
# Usage: ./migrate-db.sh [--dry-run]
# Requires: SUPABASE_DB_URL, AWS_RDS_URL
# ============================================================

SRC="${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
TGT="${AWS_RDS_URL:?Set AWS_RDS_URL}"
DRY_RUN="${1:-}"
WORK_DIR="./migration-workspace/db"

mkdir -p "$WORK_DIR"
echo "=== DATABASE MIGRATION ==="
echo "Source: $(echo "$SRC" | sed 's/:.*@/:***@/')"
echo "Target: $(echo "$TGT" | sed 's/:.*@/:***@/')"
[ "$DRY_RUN" = "--dry-run" ] && echo "⚠️  DRY RUN MODE"
echo ""

# Step 1: Export schema
echo "📦 Step 1/6: Exporting schema..."
pg_dump "$SRC" \
  --schema-only --schema=public \
  --no-owner --no-privileges --no-comments \
  2>"$WORK_DIR/schema_errors.txt" > "$WORK_DIR/schema.sql"
echo "  Schema: $(wc -l < "$WORK_DIR/schema.sql") lines"

# Step 2: Clean schema
echo "🧹 Step 2/6: Cleaning Supabase-specific references..."
cp "$WORK_DIR/schema.sql" "$WORK_DIR/schema.sql.original"

# Save RLS for reference
grep -n "CREATE POLICY\|ENABLE ROW LEVEL SECURITY" "$WORK_DIR/schema.sql" > "$WORK_DIR/rls_backup.sql" 2>/dev/null || true

# Remove Supabase roles
sed -i.bak \
  -e '/supabase_admin/d' \
  -e '/supabase_auth_admin/d' \
  -e '/supabase_storage_admin/d' \
  -e '/supabase_realtime_admin/d' \
  -e '/authenticated/d' \
  -e '/anon/d' \
  -e '/service_role/d' \
  -e '/pgsodium/d' \
  -e '/dashboard_user/d' \
  "$WORK_DIR/schema.sql"

# Remove RLS
sed -i.bak '/CREATE POLICY/,/;$/d' "$WORK_DIR/schema.sql"
sed -i.bak '/ENABLE ROW LEVEL SECURITY/d' "$WORK_DIR/schema.sql"

REMOVED=$(diff "$WORK_DIR/schema.sql.original" "$WORK_DIR/schema.sql" | grep "^<" | wc -l || echo 0)
echo "  Removed $REMOVED Supabase-specific lines"

# Step 3: Check extensions
echo "🔌 Step 3/6: Checking extension compatibility..."
EXTS=$(psql "$SRC" -t -A -c "SELECT extname FROM pg_extension WHERE extname NOT IN ('plpgsql');" 2>/dev/null)
KNOWN_UNAVAILABLE="pgsodium pg_graphql pg_net supautils"
BLOCKED=""
while IFS= read -r ext; do
  [ -z "$ext" ] && continue
  if echo "$KNOWN_UNAVAILABLE" | grep -qw "$ext"; then
    echo "  ⚠️  $ext — not available on RDS (will be skipped)"
    BLOCKED="$BLOCKED $ext"
  else
    echo "  ✅ $ext"
  fi
done <<< "$EXTS"

# Remove unavailable extension lines from schema
for ext in $BLOCKED; do
  sed -i.bak "/CREATE EXTENSION.*$ext/d" "$WORK_DIR/schema.sql"
done

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo ""
  echo "🏁 DRY RUN complete. Files in $WORK_DIR/"
  echo "   schema.sql — cleaned schema ready for restore"
  echo "   schema.sql.original — original export"
  echo "   rls_backup.sql — RLS policies for reference"
  exit 0
fi

# Step 4: Restore schema
echo "📥 Step 4/6: Restoring schema to RDS..."
psql "$TGT" -f "$WORK_DIR/schema.sql" 2>"$WORK_DIR/restore_errors.txt"
ERRORS=$(grep -c "ERROR" "$WORK_DIR/restore_errors.txt" 2>/dev/null || echo 0)
if [ "$ERRORS" -gt 0 ]; then
  echo "  ⚠️  $ERRORS errors during schema restore. Review: $WORK_DIR/restore_errors.txt"
else
  echo "  ✅ Schema restored"
fi

# Step 5: Set source read-only + export data
echo "📦 Step 5/6: Exporting data (source set to read-only)..."
psql "$SRC" -c "ALTER DATABASE postgres SET default_transaction_read_only = true;" 2>/dev/null || true

pg_dump "$SRC" \
  --data-only --schema=public \
  --no-owner --no-privileges \
  --use-copy --disable-triggers \
  -f "$WORK_DIR/data.sql"
echo "  Data: $(wc -l < "$WORK_DIR/data.sql") lines"

# Restore data
echo "  Restoring data to RDS..."
psql "$TGT" -c "SET session_replication_role = 'replica';"
psql "$TGT" -f "$WORK_DIR/data.sql" 2>"$WORK_DIR/data_errors.txt"
psql "$TGT" -c "SET session_replication_role = 'origin';"
DATA_ERRORS=$(grep -c "ERROR" "$WORK_DIR/data_errors.txt" 2>/dev/null || echo 0)
if [ "$DATA_ERRORS" -gt 0 ]; then
  echo "  ⚠️  $DATA_ERRORS errors during data restore"
else
  echo "  ✅ Data restored"
fi

# Step 6: Sync sequences
echo "🔢 Step 6/6: Syncing sequences..."
psql "$SRC" -t -A -c "
  SELECT 'SELECT setval(''' || schemaname || '.' || sequencename || ''', ' ||
         last_value || ', true);'
  FROM pg_sequences
  WHERE schemaname = 'public' AND last_value IS NOT NULL;
" > "$WORK_DIR/sync_sequences.sql"

SEQ_COUNT=$(wc -l < "$WORK_DIR/sync_sequences.sql" | tr -d ' ')
psql "$TGT" -f "$WORK_DIR/sync_sequences.sql" &>/dev/null
echo "  ✅ $SEQ_COUNT sequences synced"

echo ""
echo "========================================="
echo "DATABASE MIGRATION COMPLETE"
echo "========================================="
echo ""
echo "Files in: $WORK_DIR/"
echo "Next: Run validate.sh to verify"
echo ""
echo "⚠️  Source is still read-only. To re-enable writes (rollback):"
echo "  psql \"\$SUPABASE_DB_URL\" -c \"ALTER DATABASE postgres SET default_transaction_read_only = false;\""
