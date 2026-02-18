# Migration Playbook: Supabase → AWS

## Migration Order

```
Auth (GoTrue → Cognito) → Storage (Supabase → S3) → Database (Postgres → RDS)
```

Why this order: each step removes a Supabase schema dependency (`auth.*`, `storage.*`). The final DB migration only touches `public.*` — simplest possible pg_dump.

---

## Auth

### Export users

```bash
pg_dump "$SUPABASE_DB_URL" \
  --data-only --schema=auth --table=auth.users \
  --no-owner --no-privileges \
  -f supabase_auth_users.sql
```

### Create Cognito User Pool

Use the CloudFormation stack from `templates/aws-stack.yaml` (already created in bootstrap), or manually:

```bash
POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "${PROJECT_NAME}-users" \
  --auto-verified-attributes email \
  --username-attributes email \
  --region "$AWS_REGION" \
  --query 'UserPool.Id' --output text)

CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-name "${PROJECT_NAME}-app" \
  --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region "$AWS_REGION" \
  --query 'UserPoolClient.ClientId' --output text)

echo "COGNITO_POOL_ID=$POOL_ID"
echo "COGNITO_CLIENT_ID=$CLIENT_ID"
```

### Import users

Passwords can't be exported from GoTrue. Two strategies:

**Strategy A — Force password reset (simpler):**
```bash
# Parse supabase_auth_users.sql → CSV with email, email_verified, sub
# Use Cognito CreateUserImportJob or loop AdminCreateUser
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --message-action SUPPRESS \
  --region "$AWS_REGION"
```

**Strategy B — Migration Lambda (seamless, zero password reset):**
Keep Supabase alive during transition. Configure a Cognito User Migration Lambda that, on first sign-in, authenticates against Supabase GoTrue and migrates the user silently. See AWS docs: `UserMigration_Authentication` trigger.

### Swap auth implementation

Replace `lib/auth/` internals. The `AuthProvider` interface stays unchanged:

```typescript
// lib/auth/cognito.ts
import { CognitoIdentityProviderClient, ... } from "@aws-sdk/client-cognito-identity-provider";

export const auth: AuthProvider = {
  async signIn(email, password) { /* Cognito InitiateAuth */ },
  async signOut() { /* Cognito GlobalSignOut */ },
  async getUser(token) { /* Cognito GetUser or JWT decode */ },
};
```

### Checkpoint
- [ ] New user registration works via Cognito
- [ ] Existing user login works (Strategy A: after reset, Strategy B: seamlessly)
- [ ] `getUser()` returns correct user object
- [ ] Protected API routes still work

---

## Storage

### List and download

Supabase Storage is S3-compatible. Use `aws s3` with custom endpoint:

```bash
# Method 1: Supabase CLI
npx supabase storage ls --project-ref "$SUPABASE_REF"

# Method 2: S3-compatible (if endpoint accessible)
aws s3 ls "s3://stub/" \
  --endpoint-url "https://${SUPABASE_REF}.supabase.co/storage/v1/s3" \
  --region "$AWS_REGION"
```

If S3-compatible access isn't configured, download via Supabase SDK:

```typescript
// scripts/download-storage.ts
const { data } = await supabase.storage.from(bucket).list();
for (const file of data) {
  const { data: blob } = await supabase.storage.from(bucket).download(file.name);
  // save to ./storage-backup/bucket/file.name
}
```

### Upload to S3

```bash
aws s3 sync ./storage-backup/ "s3://${AWS_S3_BUCKET}/" --region "$AWS_REGION"
```

### Fix leaked URLs in DB

```sql
-- Find them first
SELECT column_name, table_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type IN ('text', 'character varying');

-- Then for each column that has Supabase URLs:
UPDATE <table> SET <column> = regexp_replace(
  <column>,
  'https://[^/]+\.supabase\.co/storage/v1/object/(public|sign)/[^/]+/',
  ''
) WHERE <column> LIKE '%supabase.co/storage%';
```

### Swap storage implementation

```typescript
// lib/storage/s3.ts
import { S3Client, PutObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

export const storage: StorageProvider = {
  async upload(bucket, path, file) { /* PutObjectCommand */ },
  async getUrl(bucket, path) { /* getSignedUrl or CloudFront URL */ },
  async delete(bucket, path) { /* DeleteObjectCommand */ },
};
```

### Checkpoint
- [ ] File upload returns correct key/path
- [ ] File download/display works in app
- [ ] Existing files accessible via new URLs
- [ ] No `supabase.co/storage` references remain in DB

---

## Database

### Export schema (public only)

```bash
pg_dump "$SUPABASE_DB_URL" \
  --schema-only \
  --schema=public \
  --no-owner --no-privileges --no-comments \
  2>schema_errors.txt > schema.sql
```

### Clean schema

```bash
# Remove Supabase-specific roles
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
  schema.sql

# Remove RLS (save for reference)
grep -n "CREATE POLICY\|ENABLE ROW LEVEL SECURITY" schema.sql > rls_backup.sql
sed -i.bak '/CREATE POLICY/,/;$/d' schema.sql
sed -i.bak '/ENABLE ROW LEVEL SECURITY/d' schema.sql
```

### Check extensions

```bash
# List extensions used in Supabase
psql "$SUPABASE_DB_URL" -c "SELECT extname, extversion FROM pg_extension WHERE extname NOT IN ('plpgsql');"

# Check which are available on RDS
# Common available: uuid-ossp, pgcrypto, pg_trgm, hstore, postgis
# NOT on RDS: pgsodium, pg_graphql, pg_net, supautils, plv8 (varies)
```

If incompatible extensions are found, flag them and help the user find alternatives.

### Restore schema

```bash
psql "$AWS_RDS_URL" -f schema.sql 2>restore_errors.txt
cat restore_errors.txt  # review
```

### Export data

```bash
# Set source read-only
psql "$SUPABASE_DB_URL" -c "ALTER DATABASE postgres SET default_transaction_read_only = true;"

pg_dump "$SUPABASE_DB_URL" \
  --data-only --schema=public \
  --no-owner --no-privileges \
  --use-copy --disable-triggers \
  -f data.sql
```

### Restore data

```bash
psql "$AWS_RDS_URL" -c "SET session_replication_role = 'replica';"
psql "$AWS_RDS_URL" -f data.sql 2>data_errors.txt
psql "$AWS_RDS_URL" -c "SET session_replication_role = 'origin';"
```

### Sync sequences (CRITICAL)

```bash
psql "$SUPABASE_DB_URL" -t -A -c "
  SELECT 'SELECT setval(''' || schemaname || '.' || sequencename || ''', ' ||
         last_value || ', true);'
  FROM pg_sequences
  WHERE schemaname = 'public' AND last_value IS NOT NULL;
" > sync_sequences.sql

psql "$AWS_RDS_URL" -f sync_sequences.sql
```

### Checkpoint
- [ ] Schema restored without errors (or only expected extension warnings)
- [ ] Data restored without errors
- [ ] Row counts match (run `validate.sh`)
- [ ] Sequences synced (next auto-increment won't collide)
- [ ] Application connects and reads data correctly
- [ ] INSERT operations work (sequence test)
