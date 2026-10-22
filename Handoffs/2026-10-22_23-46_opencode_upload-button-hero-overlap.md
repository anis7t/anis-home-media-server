# Handoff — 2026-10-22 23:46 IST — Upload-row/hero overlap fix and skill update

**Agent:** opencode
**Status:** Complete, committed and pushed as `ea10e7e` on `main`.
**Scope of this session:** one small frontend layout fix plus one skill update.
No backend, Rust, Flutter or database changes.

---

## 0. Repository state after this session

- Checkout: clean on `main` at `ea10e7e`, pushed (`3baf148..ea10e7e`).
- `origin/main` and `origin/feature/phase-11-opening-sequence` are both up to date.
- Only two files changed:
  - `web/src/features/library/LibraryPage.tsx` (+8/−1)
  - `web/src/features/library/LibraryPage.test.tsx` (+96)
- `web/dist/` was rebuilt (`npm run build`) so the running `MediaServerRust`
  service serves the corrected SPA from disk — **no service restart was
  needed or performed** (static files are read per-request; the restart
  notification rule applies to Rust source changes only).

### Standing secrets (unchanged, still in force)

- Admin PIN lives **only** in `E:\MediaServer\.secrets\admin_pin.txt`
  (gitignored). It was never printed or committed this session.
- The revoked old PIN remains in ~24 historical commits; **do not** rewrite
  history to scrub it (owner's prior, deliberate decision).

---

## 1. What was asked

1. Fix the misplaced Upload Media button on the library page — it overlapped
   the header/hero imagery.
2. Use the `modern-web-guidance` skill for the frontend work, and update the
   skill itself if it was out of date.

---

## 2. Skill update

- `modern-web-guidance` was outdated: installed `2026_09_04-7de96777`,
  latest `2026_10_16-6654652b`.
- Update path per the skill's own README:
  `npx modern-web-guidance@latest update` (run with `DISABLE_TELEMETRY=1`).
  The run was interrupted by a server restart but completed — verified by
  the rewritten `SKILL.md` (`--skill-version 2026_10_16-6654652b` inside it)
  and 192 refreshed guide files in
  `C:\Users\anis7\.agents\skills\modern-web-guidance\guides\`.
- For the layout work a search was run against the fresh guides
  (`negative margin overlap between stacked siblings…`). The closest hits
  (`css-layout`, etc.) cover the modern layout disciplines; the actual defect
  was app-specific, not a platform-pattern issue, so the fix follows the
  guidance's layout principles without a pattern transplant.

---

## 3. The bug: root cause

Not the button's styling — its **position relative to the hero's top margin**.

- `LibraryPage` renders the Upload Media row as the page's first element, and
  `<HeroSpotlight>` below it.
- `HeroSpotlight` has two top-margin variants:
  - `hasTopBanner=false` (default): the hero is assumed to be the page's
    first element, and its top edge **tucks under the sticky app header**
    using a *negative* top margin (`-mt-6 sm:-mt-8`).
  - `hasTopBanner=true`: a banner row exists above it, so it uses a
    *positive* margin (`mt-4 sm:mt-6`) and full `rounded-3xl` framing.
- `LibraryPage` passed `hasTopBanner={false}`, so with the Upload Media row
  above it, the hero's negative margin pulled the artwork up over that row —
  the overlap the user saw.

## 4. The fix

`web/src/features/library/LibraryPage.tsx` — the hero now renders the banner
variant when the upload row precedes it:

```tsx
<HeroSpotlight movie={featured} hasTopBanner={true} />
```

with a comment explaining why (hero is no longer the page's first element;
the tuck's negative margin would pull artwork over the row). The tucked
variant is untouched and remains correct wherever a hero starts the page.

Deliberately NOT done: moving the button inside the hero as an overlay
(nicer-looking but a larger, riskier change than the overlap called for);
touching `HeroSpotlight.tsx` (its two variants were already correct — the
caller chose the wrong one).

## 5. Tests

jsdom cannot measure rendered pixels, so the placement contract is pinned
structurally in `LibraryPage.test.tsx` (new `describe('Upload Media placement')`):

1. A featured title with artwork does render both the hero billboard and the
   Upload Media button (LCD guard for the others).
2. Document order: `uploadButton.compareDocumentPosition(hero)` reports
   `DOCUMENT_POSITION_FOLLOWING`.
3. The rendered hero carries **no** negative top margin (`-mt-` absent) and
   uses the banner variant (`rounded-3xl` present).
4. Unit guard on `HeroSpotlight` itself: `hasTopBanner={false}` still yields
   the tucked variant (`-mt-6` **and** `rounded-b-3xl`, and NOT bare
   `rounded-3xl`) — so the tuck survives for other pages/callers.

Results: `npm run test` → **42 files / 309 tests, all pass** (73.8 s).
`npm run build` → clean (only the pre-existing >500 kB chunk warnings and
the pre-existing `INEFFECTIVE_DYNAMIC_IMPORT` note about `manage.ts`).

## 6. Verification status

Verified 🟢: test suite, production build, commit pushed, skill version stamp.
Not verified on-device: no browser screenshot was taken (jsdom has no layout
engine); a visual sanity check in a real browser after a hard reload is the
one remaining confirmation, and it is trivial.

## 7. Open / carried items (unchanged by this session)

- GitHub Dependabot reports **2 moderate** vulnerabilities on the default
  branch — surfaced by the push output; pre-existing, unrelated to this
  change, worth a pass through the Dependabot UI.
- The standing work queue in `AGENTS.md` §4 is otherwise untouched: QR
  finalize auth, SSE caps, plaintext `code` column, the `-8001/-8000` Vite
  proxy cleanup (Issue 12), backups-on-same-volume, Cloudflare token scoping.

## 8. If you resume here

- Nothing is pending for this fix; it is commit `ea10e7e`, live in `dist/`.
- If the placement is revisited, change only the variant passed to
  `HeroSpotlight` in `LibraryPage.tsx` and update the three structural
  tests accordingly — do not reintroduce a negative top margin when the
  upload row exists.
