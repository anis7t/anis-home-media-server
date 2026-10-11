# PostgreSQL integration tests (Phase 3.2)

Opt-in integration tests that exercise `app.db.run_postgres_migrations()` against a
**real PostgreSQL server** through the real `psycopg` driver and `psycopg_pool`.

These are **not** a replacement for the mock-based unit tests in
`tests/test_db_adapter.py`; the two are complementary. The mocks prove our
disposal ordering and error-reporting contract. These prove what actually happens
inside PostgreSQL.

## Running

The suite is **opt-in**. Without `MEDIA_SERVER_TEST_POSTGRES_URL` every test
skips with an explicit reason:

```powershell
.\venv\Scripts\python.exe -m pytest tests/integration/test_postgres_migrations.py -q
# 20 skipped
```

To enable it, point the variable at a **dedicated, disposable** test database:

```powershell
$env:MEDIA_SERVER_TEST_POSTGRES_URL = "postgresql://USER:PASSWORD@HOST:5432/media_integration_test?sslmode=disable"
.\venv\Scripts\python.exe -m pytest tests/integration/test_postgres_migrations.py -v
```

There is deliberately **no config file, no `.env` entry, and no fallback**. The
harness reads that one variable and nothing else.

## Safety model

| Rule | Implementation |
|---|---|
| Explicit opt-in only | `conftest.test_url()` reads **only** `MEDIA_SERVER_TEST_POSTGRES_URL`. |
| Never falls back | It never reads the app's `MEDIA_SERVER_DATABASE_URL` / `DATABASE_URL`. A missing value **skips**, never retargets. |
| Name validation | The database name must contain `test` **and** must not be `media_dev`, `postgres`, `template*`, `media`, `production`, … See `FORBIDDEN_DATABASES`. Violations raise before any connection. |
| Per-test isolation | Every test gets a throwaway schema `pgi_<random>` and `search_path` points at it, so the runner's unqualified DDL lands there and nowhere else. |
| Bounded teardown | Cleanup is `DROP SCHEMA IF EXISTS "pgi_<random>" CASCADE` against a name this process generated. It cannot address a pre-existing schema. |
| No credential leakage | `describe_target()` reports host/port/dbname/user/sslmode only. The password never reaches logs, skip reasons, or assertion messages. |
| Bounded waits | Pool checkout `timeout=10`; thread joins `timeout=60`; barrier `timeout=30`; `pg_try_advisory_lock` is used where a blocking wait could hang. |

Verified failure modes:

```
media_dev                      -> REFUSE (reserved application database)
postgres                       -> REFUSE (reserved)
movies                         -> REFUSE (name lacks "test")
media_integration_test         -> ACCEPT
```

## What the tests cover

- **C1 Fresh schema** — all 7 tables and all 4 indexes exist; `details_json` is
  `TEXT`; `device_watch_history.id` is `BY DEFAULT` identity and **accepts an
  explicit id**; the `device_id` FK cascades on delete; `filename` has **no** FK
  to `movies`; `UNIQUE (device_id, filename)` is present and enforced.
- **C2 Idempotency** — a second run neither duplicates objects nor loses data.
- **C3 Version tracking** — version recorded once; a future version (999) is
  rejected; empty history applies cleanly; invalid definitions fail *before* any
  DDL; out-of-order definitions run in version order.
- **C4 Rollback** — a mid-migration failure leaves no partial DDL and no version
  row, keeps the already-committed migration, and releases the advisory lock.
- **C5 Concurrency** — two runners synchronized on a `threading.Barrier` both
  finish and record version 1 exactly once.
- **D1/D2 Pool & lock lifecycle** — checkout/return; a physically closed
  connection is discarded and replaced rather than served; a second session
  cannot take a held advisory lock and can take it once the first session's
  backend is terminated.
- **E `close()` audit** — after an error, `PostgresSession.close()` still leaves
  the pool healthy.

## Creating the test database (one-time)

```powershell
& 'E:\postgres\pgsql\bin\psql.exe' -h 127.0.0.1 -U postgres -d postgres `
    -c "CREATE DATABASE media_integration_test;"
```

Teardown is automatic (per-test schemas are dropped). To remove the database
entirely when finished with Phase 3.2:

```powershell
& 'E:\postgres\pgsql\bin\psql.exe' -h 127.0.0.1 -U postgres -d postgres `
    -c "DROP DATABASE media_integration_test;"
```

## What passing here does NOT establish

PostgreSQL is **not** production-ready, and this suite does not change the
default backend (SQLite remains default). Still outstanding:

- `TIMESTAMPTZ` vs. the application's string-oriented timestamp handling.
- End-to-end ingestion and playback against PostgreSQL.
- SQLite → PostgreSQL data migration.
- Real `Connection.close()` **failure** handling — an actual close failure was
  not induced against the driver, only normal close/lock-release paths were.