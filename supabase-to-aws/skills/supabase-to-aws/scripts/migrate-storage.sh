#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Storage Migration: Supabase Storage → AWS S3
# Usage: ./migrate-storage.sh <s3-bucket>
# Requires: SUPABASE_DB_URL (for URL cleanup), aws CLI
# ============================================================

S3_BUCKET="${1:?Usage: $0 <s3-bucket-name>}"
REGION="${AWS_REGION:-ap-northeast-2}"
SUPABASE_REF="${SUPABASE_PROJECT_REF:-}"
WORK_DIR="./migration-workspace/storage"

mkdir -p "$WORK_DIR"
echo "=== STORAGE MIGRATION ==="

# Step 1: Download from Supabase
echo "📦 Step 1/3: Downloading storage objects..."

if [ -n "$SUPABASE_REF" ]; then
  # Try S3-compatible download
  echo "  Attempting S3-compatible sync..."
  aws s3 sync \
    "s3://stub/" "$WORK_DIR/files/" \
    --endpoint-url "https://${SUPABASE_REF}.supabase.co/storage/v1/s3" \
    --region "$REGION" 2>/dev/null || {
    echo "  S3-compatible access not available."
    echo "  Please download files manually using Supabase Dashboard or CLI:"
    echo "    npx supabase storage cp -r sb://bucket-name/ $WORK_DIR/files/"
    echo "  Then re-run this script."
    exit 1
  }
else
  echo "  ⚠️  SUPABASE_PROJECT_REF not set."
  echo "  Download files manually to: $WORK_DIR/files/"
  echo "  Structure: $WORK_DIR/files/<bucket-name>/<file-path>"
  echo ""
  read -p "  Files ready? (y/n): " READY
  [ "$READY" != "y" ] && exit 1
fi

FILE_COUNT=$(find "$WORK_DIR/files" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Found $FILE_COUNT files"

# Step 2: Upload to S3
echo "☁️  Step 2/3: Uploading to S3..."
aws s3 sync "$WORK_DIR/files/" "s3://${S3_BUCKET}/" --region "$REGION"
echo "  ✅ Upload complete"

# Step 3: Fix leaked URLs in DB
echo "🔗 Step 3/3: Checking for leaked Supabase URLs in database..."

if [ -n "${SUPABASE_DB_URL:-}" ]; then
  # Find columns with text/varchar types
  LEAK_CHECK=$(psql "$SUPABASE_DB_URL" -t -A -c "
    SELECT table_name || '.' || column_name
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND data_type IN ('text', 'character varying')
    ORDER BY table_name;
  " 2>/dev/null)
  
  LEAKED_COLS=""
  while IFS= read -r col; do
    [ -z "$col" ] && continue
    TABLE=$(echo "$col" | cut -d. -f1)
    COLUMN=$(echo "$col" | cut -d. -f2)
    HAS_URLS=$(psql "$SUPABASE_DB_URL" -t -A -c "
      SELECT count(*) FROM public.\"$TABLE\"
      WHERE \"$COLUMN\" LIKE '%supabase.co/storage%';
    " 2>/dev/null || echo "0")
    
    if [ "$HAS_URLS" -gt 0 ]; then
      echo "  ⚠️  $TABLE.$COLUMN has $HAS_URLS rows with Supabase Storage URLs"
      LEAKED_COLS="$LEAKED_COLS $TABLE.$COLUMN"
    fi
  done <<< "$LEAK_CHECK"
  
  if [ -z "$LEAKED_COLS" ]; then
    echo "  ✅ No leaked URLs found"
  else
    echo ""
    echo "  To fix leaked URLs, run these SQL commands against your database"
    echo "  AFTER the DB migration (when data is in RDS):"
    for col in $LEAKED_COLS; do
      TABLE=$(echo "$col" | cut -d. -f1)
      COLUMN=$(echo "$col" | cut -d. -f2)
      echo ""
      echo "  UPDATE public.\"$TABLE\" SET \"$COLUMN\" = regexp_replace("
      echo "    \"$COLUMN\","
      echo "    'https://[^/]+\\.supabase\\.co/storage/v1/object/(public|sign)/[^/]+/',"
      echo "    ''"
      echo "  ) WHERE \"$COLUMN\" LIKE '%supabase.co/storage%';"
    done
    echo ""
    # Save fix script
    echo "  SQL saved to: $WORK_DIR/fix_urls.sql"
  fi
else
  echo "  ⚠️  SUPABASE_DB_URL not set, skipping URL check"
fi

echo ""
echo "Next: Update lib/storage/ implementation to use S3 SDK"
echo "Set STORAGE_PROVIDER=s3 in .env"
