# Checklists

## Pre-Migration Checklist

### Tools
- [ ] `pg_dump` installed (version ≥ Supabase PG version)
- [ ] `psql` installed
- [ ] `aws` CLI v2 installed and configured (`aws sts get-caller-identity` succeeds)
- [ ] `node` / `npx` installed

### Access
- [ ] `SUPABASE_DB_URL` is set and reachable (`psql "$SUPABASE_DB_URL" -c "SELECT 1"`)
- [ ] `AWS_RDS_URL` is set and reachable (or AWS bootstrap not yet run)
- [ ] AWS IAM user has permissions: `rds:*`, `cognito-idp:*`, `s3:*`, `cloudformation:*`

### Codebase Readiness
- [ ] Audit score is 🟢 or 🟡
- [ ] No blocking violations (Supabase SDK in business logic without ORM alternative)
- [ ] Auth abstraction exists (`lib/auth/` with provider-agnostic interface)
- [ ] Storage abstraction exists (`lib/storage/` with provider-agnostic interface)
- [ ] No hardcoded Supabase Storage URLs in database
- [ ] `DATABASE_URL` env var is the only connection source
- [ ] Test suite exists and passes against current Supabase DB

---

## Auth Migration Checklist

- [ ] Users exported from `auth.users`
- [ ] Cognito User Pool created
- [ ] Cognito App Client created (no secret for SPA)
- [ ] Users imported to Cognito (Strategy A or B chosen)
- [ ] `lib/auth/` swapped to Cognito implementation
- [ ] `AUTH_PROVIDER=cognito` in env
- [ ] New user registration works
- [ ] Existing user login works
- [ ] Password reset flow works
- [ ] JWT/session validation works in API routes
- [ ] OAuth providers reconfigured in Cognito (if used)

---

## Storage Migration Checklist

- [ ] All buckets listed
- [ ] All objects downloaded
- [ ] Objects uploaded to S3
- [ ] S3 bucket policy configured (public read for public buckets, presigned for private)
- [ ] Leaked full URLs fixed in database
- [ ] `lib/storage/` swapped to S3 implementation
- [ ] `STORAGE_PROVIDER=s3` in env
- [ ] File upload works
- [ ] File download/display works
- [ ] Existing files accessible
- [ ] CORS configured on S3 bucket (if browser uploads)

---

## Database Migration Checklist

- [ ] Schema exported (`public` only, no owner/privileges)
- [ ] Schema cleaned (Supabase roles removed, RLS removed)
- [ ] Extension compatibility verified
- [ ] Schema restored to RDS without blocking errors
- [ ] Source set to read-only
- [ ] Data exported
- [ ] Data restored (with triggers disabled)
- [ ] Sequences synced
- [ ] Row counts match source ↔ target
- [ ] INSERT test passes (sequence verification)
- [ ] Application test suite passes against RDS

---

## Cutover Checklist

- [ ] All phase checklists above completed
- [ ] `.env` updated: `DATABASE_URL`, `AUTH_PROVIDER`, `STORAGE_PROVIDER`
- [ ] CI/CD env vars updated
- [ ] Deployment triggered with new env
- [ ] Smoke test in production
- [ ] Monitoring configured (CloudWatch for RDS, Cognito metrics)
- [ ] Supabase project kept alive (14-day rollback window)
- [ ] `@supabase/supabase-js` removed from `package.json`
- [ ] Supabase-specific env vars removed
- [ ] Team notified
- [ ] Rollback plan documented and rehearsed

---

## Post-Migration Cleanup (Day 14+)

- [ ] Supabase project paused or deleted
- [ ] `lib/realtime/` replaced with own WebSocket or AppSync (if Realtime was used)
- [ ] RDS backup schedule configured
- [ ] RDS scaling policy configured
- [ ] Cost monitoring set up (RDS, Cognito, S3)
- [ ] Security audit: no Supabase credentials remain in codebase or CI/CD
