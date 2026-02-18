# My Claude Plugin Marketplace

Database portability and migration tools for Claude Code.

## Installation

```bash
# Add marketplace
/plugin marketplace add YOUR_GITHUB_USERNAME/my-claude-plugins

# Install plugin
/plugin install supabase-to-aws@my-claude-plugins
```

## Plugins

### supabase-to-aws

Full-lifecycle Supabase ↔ AWS portability plugin with three modes:

| Mode | Command | Purpose |
|------|---------|---------|
| **AUDIT** | `/supabase-to-aws:db-audit` | Scan codebase coupling, generate readiness score |
| **GUARD** | `/supabase-to-aws:db-guard` | Install portability rules (prototype/production) |
| **MIGRATE** | `/supabase-to-aws:db-migrate` | Execute migration: Auth → Storage → Database |

**Agent:** `migration-advisor` — Expert advisor for migration strategy and troubleshooting.

### What it does

- **Audit** any codebase (new or legacy) for Supabase lock-in — outputs 🟢🟡🟠🔴 score
- **Guard** during development with two-phase rules (prototype allows SDK, production enforces ORM)
- **Migrate** services-first: GoTrue→Cognito, Storage→S3, Postgres→RDS
- **One-command AWS setup** via CloudFormation (VPC + RDS + Cognito + S3)
- **Validation** suite with row counts, sequence sync, connectivity checks

## Quick Start

```bash
# 1. Audit current project
/supabase-to-aws:db-audit .

# 2. Install guard rules
/supabase-to-aws:db-guard prototype

# 3. When ready, migrate
/supabase-to-aws:db-migrate all --dry-run
```
