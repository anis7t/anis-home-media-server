# Triage Plan — Issue 14.2: "Account Icon Missing Across Pages" (Web)

**Date:** 2026-10-23 (IST 03-18); corrected 2026-10-23 (IST 16-30)
**Issue:** [`docs/Current issues.md`](../docs/Current%20issues.md) → Issue 14, fault 2
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **Closed — the original diagnosis was wrong, and the change it produced was reverted.**

---

## 1. Fault as reported

> The user account icon is **not present throughout all pages** of the web app — some pages lack the
> signed-in identity affordance.

## 2. What was actually true (established 2026-10-23)

The account affordance is rendered by the **shared `AppShell` header**, which wraps every route in
`web/src/main.tsx`. It was already present on every page:

| State | Header shows | Where |
|---|---|---|
| signed out | the **"Sign in"** pill | `AppShell.tsx` ~line 345 |
| signed in | the **account avatar**, a menu trigger | `AppShell.tsx` ~line 222 |

The one route where it is **deliberately** absent is `/watch/*`, and that is correct:
`AppShell.tsx:221` — *"Hidden on the player, where a stray nav click would interrupt playback."*

So "missing across pages" was a misreading of a header that shows **"Sign in"** when signed out
rather than a user glyph. Nothing was missing.

## 3. What the first fix did, and why it was wrong

The first pass added a **second** `Avatar` to each page's own header row, starting with
`LibraryPage`:

```tsx
<div className="flex flex-wrap items-center justify-end gap-2">
  <button>Upload Media</button>
  <Avatar size="sm" />     {/* added for 14.2 */}
</div>
```

That `Avatar` was not gated on auth, and it sat in a row **below** the header. Measured in a real
browser at 1440×900:

| State | Header row | Row below the header |
|---|---|---|
| signed out | "Sign in" at `(1340,16)` | silhouette at `(1388,103)` |
| signed in | avatar 36 px at `(1380,16)` | avatar 28 px at `(1388,103)` |

The owner reported exactly that:

> the user icon and sign in icon both are being displayed. why? the items should be in the same row
> of the header... no 2 rows

## 4. The fix (2026-10-23)

- **Removed** the page-level `<Avatar>` (and its import) from `LibraryPage.tsx`, restoring that
  file to `HEAD`.
- **Reverted** the companion `Avatar.tsx` change (`useAuth` → `useOptionalAuth`). It existed only to
  keep the duplicate renderable outside a provider; with the duplicate gone the component is only
  mounted inside `<AuthProvider>`, so the change had no purpose.
- **Added a regression test** — `LibraryPage.test.tsx` → *"does not render a second account
  affordance beside Upload Media"*. It mounts the page inside `AuthProvider` with a signed-in
  `/api/auth/me` and asserts that no `role="img"` named after the account is rendered beside the
  Upload button. **Proved to fail before the fix** (`expected <span aria-label="Anis Parvez"
  role="img"> to be null`) and **to pass after** it.

The **"Upload Media" row itself stays**. It is a page action, not a header, and that is where the
button has always lived. The owner chose this narrow option over moving the button into the header
row.

## 5. Verification

- `web`: `npm run test` — 42 files / **317 tests**, 0 failures (316 before the new test, 9 of which
  the duplicate had been breaking).
- `npm run typecheck`, `npm run lint` (warnings only), `npm run build` — clean.
- Live, rebuilt `web/dist` (`index-BiCQfQFI.js`) served from `/`:
  - signed out at 1440×900 — **no avatar anywhere**, one "Sign in" control in the header;
  - signed in at 1440×900, 1280×800 and 390×844 — **exactly one** account glyph, in the header;
  - the header never wraps at any of those widths.
- Every route checked signed in — `/`, `/manage`, `/devices`, `/manual`, `/download`,
  `/transcodes` — carries **exactly one** account glyph, and it is in the header. `/account`
  carries two, and that is correct: the header trigger **plus** the account page's own large
  profile avatar (`AccountPage.tsx:119`), which is page content inside the "signed in as" card, not
  a second header affordance.
- No Rust change, so no service restart was needed.

## 6. Standing rule this establishes

**The account affordance lives in the shared header, once.** Do not add an `Avatar` to a page's own
toolbar — pages do not own identity chrome, and an unconditional avatar in a page row reads as a
second, contradictory sign-in state. `/watch/*` is the single, deliberate exception.

---

## 7. Superseded audit (kept for the record)

The original audit, written before the correction above, claimed:

| Route | Claim |
|---|---|
| `/devices` | "account icon/affordance not explicitly rendered in header" |
| `/manage` | "pending" |
| `/watch/*` | "pending implementation" |
| `/download`, `/manual` | "pending implementation" |

Every one of those rows was wrong in the same way: it looked for an `Avatar` **inside the page
component** and concluded the affordance was missing, when the affordance is supplied by the shell
around the page. Implementing that audit would have added the same duplicate to five more pages.
