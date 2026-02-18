# Database Portability Rules: Supabase ↔ AWS RDS

## Purpose

Supabase is a PostgreSQL host for rapid development. The goal: migrate to AWS RDS by changing `DATABASE_URL` and swapping auth/storage adapters — not rewriting business logic.

## Phase Detection

Phase is set by `DB_PHASE` env var. If unset, infer from codebase:
- No ORM + Supabase SDK everywhere → treat as `prototype`
- Drizzle/Prisma present + mixed SDK usage → treat as `transition` (prompt user)
- ORM-only data access + abstracted auth/storage → treat as `production`

---

## Phase: Prototype (`DB_PHASE=prototype`)

Rules are relaxed. Speed over portability.

**Allowed:**
- Supabase SDK everywhere (`.from()`, `.select()`, etc.)
- RLS-only auth
- Direct Supabase Storage URLs in DB
- Dashboard SQL edits

**Required even in prototype:**
- Use `DATABASE_URL` env var (never hardcode connection strings)
- Mark all Supabase-coupled code: `// PROTOTYPE_ONLY: [what needs to change]`
- Keep migration files in `migrations/` when writing schema changes

**Phase transition:** When user says "switch to production", "apply portability rules", or sets `DB_PHASE=production`:
1. Run audit (scan for `PROTOTYPE_ONLY` markers + Supabase SDK grep)
2. Generate refactor plan
3. Offer file-by-file refactor assistance

---

## Phase: Production (`DB_PHASE=production`)

All rules enforced.

### Rule 1 — Data access via Drizzle ORM only

No `@supabase/supabase-js` for data CRUD in business logic. No `.from()`, `.select()`, `.insert()`, `.update()`, `.delete()`, `.rpc()`.

**Exemption:** Supabase SDK inside quarantined directories (Rule 3) is allowed, including Realtime `.from()` subscriptions.

### Rule 2 — Single DB connection

`lib/db/client.ts` reads `DATABASE_URL`. No other file creates DB connections. Use Drizzle Kit for migrations. Do not use `supabase db diff` or `supabase db push`.

### Rule 3 — Supabase SDK quarantine

`@supabase/supabase-js` imports allowed only in:
- `lib/auth/` — Auth (GoTrue)
- `lib/storage/` — Storage
- `lib/realtime/` — Realtime

Each exports a provider-agnostic interface. No Supabase SDK in API routes, services, or components.

### Rule 4 — No RLS-only authorization

RLS is supplementary. Authorization must exist in app code. RDS has no RLS.

### Rule 5 — Client-side data via own API routes

Browser code accesses data through your API routes only. No PostgREST (`/rest/v1/`) or direct Supabase URL calls from client.

### Rule 6 — User data in public schema

Sync user metadata to `public.profiles` (trigger or webhook). Never query `auth.users` from business logic.

### Rule 7 — Relative storage paths only

Store keys/paths in DB, not full provider URLs. Construct URLs at read time via `lib/storage/`.

### Rule 8 — No Supabase Edge Functions

Deno runtime is incompatible with standard postgres driver. Use own API routes or Lambda.

### Rule 9 — Migrations via Drizzle Kit only

`migrations/` is the single source of truth. Dashboard SQL edits don't exist.

### Rule 10 — Env var structure

```
DB_PHASE=prototype|production
DATABASE_URL=postgresql://...
AUTH_PROVIDER=supabase|cognito|authjs
STORAGE_PROVIDER=supabase|s3
```

---

## Script/Seed Exemption

Files in `scripts/`, `seed/`, `tests/` are exempt from the violation procedure but must include `// DB_PORTABILITY_VIOLATION` comments.

---

## ⚠️ Violation Request Policy (Production only)

If the user requests code violating production rules:

1. State which rule is violated
2. Explain the concrete migration consequence
3. Offer a compliant alternative
4. Only if user rejects alternative AND explicitly reconfirms → proceed with:
   `// ⚠️ DB_PORTABILITY_VIOLATION: Rule [N] — [reason]. Must rewrite for RDS.`
