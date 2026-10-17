# Walkthrough — Sub-Slice 7E.4: Test Suite Modernization & Python Dependency Pruning (`requirements.txt`)

## 1. Overview & Objective
Sub-Slice 7E.4 represents the fourth milestone of **Phase 7 Backlog: Slice 7E (Legacy Flask Retirement)**.
The objective of this sub-slice was to decommission the obsolete Python unit and integration tests in `tests/` that tested internal methods of the decommissioned Flask backend (`app/`), while strictly preserving historical streaming and concurrency benchmark records in `tests/load/`.

Furthermore, `requirements.txt` was pruned to remove `Flask`, `waitress`, `gunicorn`, `WMI`, and `pywin32`, retaining only the lightweight libraries required for operational tooling and probes (`requests`, `python-dotenv`, `psycopg[binary]`, `psycopg-pool`).

---

## 2. Completed Actions

### A. Python Dependency Pruning (`requirements.txt`)
- Pruned obsolete web framework and WSGI dependencies:
  - Removed `Flask>=3.0,<4`
  - Removed `waitress>=3.0,<4`
  - Removed `gunicorn>=23.0`
  - Removed `pywin32>=306`
  - Removed `WMI>=1.5.1`
- Retained core operational requirements:
  - `requests>=2.31,<3`
  - `python-dotenv>=1.0,<2`
  - `psycopg[binary]>=3.2.0,<4`
  - `psycopg-pool>=3.2.0,<4`

### B. Obsolete Flask Tests Decommissioned
- Deleted 52 obsolete Python test files in `tests/` (`test_*.py`).
- Deleted `tests/conftest.py`, `tests/_cache_test_support.py`, `tests/_isolation_paths.py`, `tests/_write_guard.py`.
- Deleted `tests/integration/` (`test_postgres_migrations.py`, `test_postgres_timestamps.py`, `conftest.py`).
- Strictly preserved `tests/load/` containing historical streaming and concurrency benchmark profiles (`benchmark_results_*.json`).

---

## 3. Verification & Test Outcomes

### A. Operational Tooling Verification under Pruned Requirements
```powershell
python scanner.py
python scripts/probe_android_api.py
python scripts/probe_phase_8_contracts.py
```
**Outcome**: All tools executed cleanly with exit code 0 and zero missing dependency errors under the pruned requirements set.

### B. Rust Integration Test Suite
```powershell
cargo test --test admin_auth_test --test scan_test --test spa_serving_test -- --test-threads=1 # (in rust/)
```
**Outcome**: All **16/16** integration tests across the 3 representative suites passed cleanly.

### C. Web Frontend Vitest Suite
```powershell
npm run test # (in web/)
```
**Outcome**: All **212/212** Vitest tests passed across all 30 test files.

---

## 4. Next Step
Sub-Slice 7E.4 is complete. Ready for **Sub-Slice 7E.5: Architectural Documentation Modernization & Final Sign-Off**.
