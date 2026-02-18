#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Auth Migration: Supabase GoTrue → AWS Cognito
# Usage: ./migrate-auth.sh <cognito-pool-id>
# Requires: SUPABASE_DB_URL, aws CLI configured
# ============================================================

SRC="${SUPABASE_DB_URL:?Set SUPABASE_DB_URL}"
POOL_ID="${1:?Usage: $0 <cognito-pool-id>}"
REGION="${AWS_REGION:-ap-northeast-2}"
WORK_DIR="./migration-workspace/auth"

mkdir -p "$WORK_DIR"
echo "=== AUTH MIGRATION ==="

# Step 1: Export users
echo "📦 Step 1/3: Exporting users from Supabase..."
psql "$SRC" -t -A -c "
  SELECT json_build_object(
    'email', email,
    'email_confirmed', (email_confirmed_at IS NOT NULL),
    'created_at', created_at,
    'id', id
  )
  FROM auth.users
  WHERE deleted_at IS NULL
  ORDER BY created_at;
" > "$WORK_DIR/users.jsonl"

USER_COUNT=$(wc -l < "$WORK_DIR/users.jsonl" | tr -d ' ')
echo "  Found $USER_COUNT users"

# Step 2: Import to Cognito
echo "👤 Step 2/3: Creating users in Cognito..."
CREATED=0; SKIPPED=0; ERRORS=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  EMAIL=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null || continue)
  VERIFIED=$(echo "$line" | python3 -c "import sys,json; print(str(json.load(sys.stdin)['email_confirmed']).lower())" 2>/dev/null || echo "false")
  
  # Check if user already exists
  EXISTS=$(aws cognito-idp admin-get-user \
    --user-pool-id "$POOL_ID" \
    --username "$EMAIL" \
    --region "$REGION" 2>/dev/null && echo "yes" || echo "no")
  
  if [ "$EXISTS" = "yes" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  
  aws cognito-idp admin-create-user \
    --user-pool-id "$POOL_ID" \
    --username "$EMAIL" \
    --user-attributes \
      Name=email,Value="$EMAIL" \
      Name=email_verified,Value="$VERIFIED" \
    --message-action SUPPRESS \
    --region "$REGION" &>/dev/null && \
    CREATED=$((CREATED + 1)) || \
    ERRORS=$((ERRORS + 1))
  
  # Rate limit: Cognito allows ~10 requests/sec
  sleep 0.1
done < "$WORK_DIR/users.jsonl"

echo "  ✅ Created: $CREATED"
echo "  ⏭️  Skipped (existing): $SKIPPED"
[ "$ERRORS" -gt 0 ] && echo "  ❌ Errors: $ERRORS"

# Step 3: Summary
echo ""
echo "📋 Step 3/3: Summary"
echo "  Users will need to reset passwords on first login."
echo "  For seamless migration, configure a Cognito User Migration Lambda"
echo "  that authenticates against Supabase GoTrue during the transition period."
echo ""
echo "  Next: Update lib/auth/ implementation to use Cognito SDK"
echo "  Set AUTH_PROVIDER=cognito in .env"
