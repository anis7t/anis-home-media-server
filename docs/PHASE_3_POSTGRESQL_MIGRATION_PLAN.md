# Phase 3 PostgreSQL Migration — Implementation Plan

> **Status:** APPROVED BY USER (2026-10-14 22:50 IST)  
> **Author:** Antigravity  
> **Workspace:** `E:\MediaServer`  
> **Governing Roadmap:** [`docs/FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md`](FLASK_RUST_REACT_POSTGRES_MIGRATION_ROADMAP.md)  
> **Exit Gate:** Data transfer and recovery demonstrated; application passes representative regression tests against PostgreSQL; write ownership unambiguous.

---

## 1. Executive Summary & Design Architecture

This implementation plan delivers **Phase 3 (PostgreSQL Migration)** for Anis' Home Media Server. Following the governing migration roadmap (Rule 2: *Preserve behavior before replacing implementation*, Rule 4: *Separate risky changes*, Rule 8: *Avoid premature abstraction*), we use **Option 1**:

- **Native psycopg 3 / psycopg-pool Dual-Backend Adapter**: Leverages [`app/db.py`](../app/db.py), which already contains thread-safe pooling ([`PostgresSession`](../app/db.py)), parameter tokenization (`normalize_sql`), advisory locking (`pg_advisory_lock`), and schema migration runners.
- **Zero Flask Service Refactoring**: Preserves the ~42 query call sites across `app/services/*.py` and `app/routes/*.py`. Database backend is switched via a single environment variable: `MEDIA_SERVER_DATABASE_BACKEND=postgres` (or `sqlite`).
- **Target Alignment with Rust (Phases 4–6)**: The raw SQL schema DDL and query structures map directly 1-to-1 to Rust SQLx compile-time checked queries (`query!`, `query_as!`), avoiding ephemeral ORM abstractions.
- **Zero Data Loss Guarantee**: Live SQLite `media.db` is never modified during migration; the migration reads from verified backups or live SQLite read-only. Instant rollback to SQLite is preserved at all times.

---

## 2. Source Data Inventory (`media.db`)

Live SQLite database contains **852 rows across 10 active application tables** (plus SQLite sequence and 1 deprecated prototype table):

| Table | Rows | Primary Key | Foreign Keys / Constraints | Notes |
|---|---|---|---|---|
| `movies` | 44 | `filename` | TMDB index | Full metadata, posters, backdrops, release dates |
| `devices` | 375 | `device_id` | `idx_devices_last_seen` | Client hints, hardware models, IP tracking |
| `device_watch_history` | 112 | `id` (Auto-inc) | FK to `devices(device_id)` ON DELETE CASCADE; UNIQUE(`device_id`, `filename`) | Auto-increment primary key `id` |
| `ip_cache` | 292 | `ip` | — | Reverse IP / geo / ISP cache |
| `progress` | 30 | `filename` | `idx_progress_updated` | Direct playback positions |
| `settings` | 3 | `key` | — | Retention policy, admin pin hash, configuration |
| `users` | 1 | `id` (Auto-inc) | Google sub UNIQUE, email | Admin / viewer accounts |
| `auth_tokens` | 0 | `id` (Auto-inc) | FK to `users(id)` ON DELETE CASCADE | Mobile / TV pairing tokens |
| `oauth_attempts` | 0 | `state` | — | Short-lived OAuth state nonces |
| `schema_migrations` | 1 | `version` | — | SQLite schema version 1 |
| *`device_progress`* | 0 | `(device_id, filename)` | — | Legacy empty prototype table (excluded) |

---

## 3. Step-by-Step Implementation Sequence

### Step 1: PostgreSQL Service Automation & Local Cluster Setup
1. Author Windows batch scripts:
   - `scripts/start_postgres.bat`: Starts PostgreSQL 18.4 (`E:\postgres\pgsql\bin\pg_ctl.exe -D E:\pgdata start`) and verifies port 5432 availability.
   - `scripts/stop_postgres.bat`: Gracefully stops the PostgreSQL cluster (`pg_ctl.exe -D E:\pgdata stop -m fast`).
2. Start PostgreSQL 18.4 cluster at `E:\pgdata`.
3. Create target application database `media_server` and test database `media_integration_test` using `psql.exe`.

### Step 2: Automated SQLite-to-PostgreSQL Migration Utility (`scripts/migrate_sqlite_to_postgres.py`)
1. Create CLI utility `scripts/migrate_sqlite_to_postgres.py`:
   - Checks source SQLite database integrity (`PRAGMA integrity_check`).
   - Connects to PostgreSQL `media_server`.
   - Runs `app.db.run_postgres_migrations()` inside advisory lock (`PG_MIGRATION_ADVISORY_LOCK_KEY`).
   - Copies tables in strict dependency order:
     1. `settings`
     2. `ip_cache`
     3. `movies`
     4. `progress`
     5. `devices`
     6. `device_watch_history` (depends on `devices`)
     7. `users`
     8. `auth_tokens` (depends on `users`)
     9. `oauth_attempts`
   - Preserves auto-increment IDs (`id`) on `device_watch_history`, `users`, `auth_tokens` using `BY DEFAULT AS IDENTITY`.
   - Resets PostgreSQL identity sequences (`setval`) after loading each table.
   - Converts SQLite ISO string timestamps (`DATETIME`) into timezone-aware UTC Python `datetime` objects for PostgreSQL `TIMESTAMPTZ`.
   - Reconciles 100% row counts and validates key records between SQLite and PostgreSQL.
   - Produces a JSON audit report in `backups/migration_report_<timestamp>.json`.

### Step 3: Comprehensive Test Verification
1. **Real-PostgreSQL Integration Tests**:
   - Point `MEDIA_SERVER_TEST_POSTGRES_URL` to `postgresql://postgres:postgres@127.0.0.1:5432/media_integration_test?sslmode=disable`.
   - Run `tests/integration/test_postgres_migrations.py` (20 tests).
   - Run `tests/integration/test_postgres_timestamps.py` (6 tests).
2. **Application Regression Tests under PostgreSQL**:
   - Run core Flask test suites with `MEDIA_SERVER_DATABASE_BACKEND=postgres` and `MEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server`:
     - `tests/test_api_contracts.py`
     - `tests/test_movies_api.py`
     - `tests/test_devices.py`
     - `tests/test_manage.py`
     - `tests/test_admin_auth.py`
     - `tests/test_timestamp_compat.py`
     - `tests/test_db_adapter.py`
3. **Frontend Verification**:
   - Run Vitest suite: `npm test -- --run` (172 tests).

### Step 4: Documentation & Walkthrough
1. Update `docs/MIGRATION_STATUS.md` and `docs/PROJECT_STATUS.md`.
2. Generate comprehensive post-completion walkthrough document (`docs/PHASE_3_POSTGRESQL_MIGRATION_WALKTHROUGH.md`).
3. Prepare session handoff.

---

## 4. Rollback & Cutover Runbook

- **Cutover**:
  1. Add/update `.env`:
     ```env
     MEDIA_SERVER_DATABASE_BACKEND=postgres
     MEDIA_SERVER_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/media_server
     ```
  2. Restart Windows persistent service: `scripts\restart_service.bat` (elevated).
- **Rollback Window**:
  1. If any anomaly occurs, update `.env`:
     ```env
     MEDIA_SERVER_DATABASE_BACKEND=sqlite
     ```
  2. Restart Windows service: `scripts\restart_service.bat`.
  3. Live SQLite `media.db` remains 100% intact, guaranteeing instant zero-loss rollback.
