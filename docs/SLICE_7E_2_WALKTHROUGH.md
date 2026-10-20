# Walkthrough — Sub-Slice 7E.2: Legacy UI Templates & Static Asset Retirement

## 1. Overview & Objective
Sub-Slice 7E.2 represents the second milestone of **Phase 7 Backlog: Slice 7E (Legacy Flask Retirement)**.
The objective of this sub-slice was to decommission all deprecated Jinja HTML templates (`templates/`), legacy static styles, scripts, and vendor libraries (`static/`), and legacy template-era diagnostic scripts from the root directory.

All browser clients and remote tunnel requests are served exclusively by the modern React SPA bundle (`web/dist/`) through Axum's `SpaFallbackService` on port 8000.

---

## 2. Completed Actions

### A. Decommissioned Legacy Jinja HTML Templates (`templates/`)
- Removed all 9 legacy Jinja HTML template files:
  - `templates/details.html` (Movie details view)
  - `templates/devices.html` (Connected devices dashboard)
  - `templates/download.html` (Legacy download page)
  - `templates/error.html` (Generic error page)
  - `templates/intro-overlay.html` (Legacy canvas intro overlay — **NOT ported**; see the correction below)
  - `templates/library.html` (Catalog grid)
  - `templates/manage.html` (Storage and library management)
  - `templates/manual.html` (User guide)
  - `templates/player.html` (Legacy 93 KB video player template)

### B. Decommissioned Legacy Static Assets (`static/`)
- Removed the legacy asset directory:
  - `static/css/` (`main.css`, `seekbar-youtube.css`)
  - `static/js/` (`details.js`, `library.js`, `nav.js`, `nav-original.js`, `seekbar-youtube.js`)
  - `static/vendor/` (`hls.min.js`)

### C. Decommissioned Legacy Diagnostics & Scripts
- Removed one-off template-era scripts:
  - `tmdb_test.py`
  - `tmdb_diag.py`
  - `tmdb_details_test.py`
  - `restart_service_for_cast.cmd`

> ## ⚠️ Correction — 2026-10-20: this sub-slice lost a feature
>
> **The line above originally read *"templates/intro-overlay.html (Legacy canvas intro overlay;
> ported to React `<BrandIntroOverlay>`)"*. That claim was false, and it was the claim that let
> the loss go unnoticed.**
>
> The brand opening sequence was **never ported**. `web/src/components/brand/BrandIntroOverlay.tsx`
> was *planned* in the Phase 0 target architecture
> ([`docs/PHASE_0_ARCHITECTURE_AUDIT.md`](PHASE_0_ARCHITECTURE_AUDIT.md)) but never built, and no
> `BrandIntro`/`IntroOverlay` component exists in `web/src` or in any branch's history. This
> sub-slice deleted the only implementation — the Jinja template — and the web app has had no
> intro since 2026-10-18.
>
> **Why it was missed:** the verification in §3 below is an **architecture** check — that the SPA
> serves the pages without the Jinja templates. It passed, because it was true. Nobody asked
> whether the SPA still had the **features** the templates carried. A decommissioning sign-off
> must diff capabilities, not just mechanisms.
>
> **Not lost:** the Flutter client still has it (`flutter_client/lib/features/intro/`, with its own
> copy of the portrait video and two test files); all 293 MB of assets are intact in
> `docs/opening-sequence/`; the design and the three web invariants are intact.
>
> **Status: OPEN.** The web port is item 5 of the `AGENTS.md` work queue. Full record:
> [`docs/OPENING_SEQUENCE.md`](OPENING_SEQUENCE.md) §0 and
> [`docs/SLICE_7E_WALKTHROUGH.md`](SLICE_7E_WALKTHROUGH.md) §6.

---

## 3. Verification & Test Outcomes

### A. React Production Bundle Build
```powershell
npm run build # (in web/)
```
**Outcome**:
- `tsc -b` completed with **0 errors**.
- Vite production build succeeded in **684ms**.
- SPA shell (`dist/index.html`) and hashed assets generated cleanly.

### B. Rust SPA Fallback & Static Serving Tests
```powershell
cargo test --test spa_serving_test # (in rust/)
```
**Outcome**:
- `test_serves_spa_index_at_root` — **PASSED** (HTTP 200 text/html)
- `test_client_side_routing_fallback` — **PASSED** (Returns `index.html` on client routes)
- `test_static_asset_serving_with_immutable_cache` — **PASSED** (`public, max-age=31536000, immutable`)
- `test_api_endpoints_retain_precedence_over_spa` — **PASSED**
- `test_missing_api_and_media_routes_return_404_json_not_html` — **PASSED**

### C. Android Client API Contract Verification
```powershell
python scripts/probe_android_api.py
```
**Outcome**: All **22/22** endpoints responded per contract (zero HTML pages requested; 100% API contract compliance).

---

## 4. Next Step
Sub-Slice 7E.2 is complete. Ready for **Sub-Slice 7E.3: Legacy Python Backend (`app/`) & Launchers Decommissioning**.
