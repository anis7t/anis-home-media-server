# Triage — Issue 14.6: Add-Device Flow (QR Code / URL / Token)

**Date:** 2026-10-23 (IST 03-18; corrected 23:20)
**Issue:** [`docs/Current issues.md`](Current%20issues.md) → Issue 14, fault 6
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **Fixed 2026-10-23** — the exposed token was revoked and the panel was removed.

---

## 1. Fault

In the devices menu, the **Add device** option: after entering a device name it shows a **QR code, a URL and a token**. The owner asks:

- What am I supposed to do with the QR code?
- The URL is **non-functional**.
- Where was I supposed to enter the token?
- Why does this whole thing exist, since QR login is already handled?

## 2. What the flow actually did (read from the code, not inferred)

The first triage pass called the URL and token "legacy remnants" and chose to hide them. Reading
the implementation showed the panel's real behaviour was different — and stronger than that:

- **Minting** (`POST /api/auth/tokens`, form in `web/src/features/account/AccountPage.tsx`) creates
  an `auth_tokens` row: a CSPRNG `ms_…` secret, stored only as a SHA-256 hash, labelled with the
  name typed into the form. The form sends no `validity_days`, so the server default applies:
  **365 days**.
- **The QR and the URL are the same artefact.** `pairing_url` is
  `https://<host>/auth/pair#token=ms_…`; the QR component merely encodes that string.
- **Redemption is a web-browser sign-in.** `GET /auth/pair` serves a page whose inline script posts
  the fragment to `POST /auth/pair`; that handler calls `AuthService::pair_token`, which creates a
  **30-day `sessions` row** for the token's user and sets the session cookie. Any browser that opens
  the link is signed in as that account, with no Google step.
- **The token is not consumed and is not device-bound.** `pair_token` never sets `revoked_at` or
  `last_used_at`; the same link works repeatedly for its whole lifetime, in any number of browsers.
- **It does not add a device.** No `devices` row is created by minting. The name is a label on the
  token, not a device name; devices appear when a client actually connects under its own
  `web_…` / `dev_…` id.
- **The shipped Flutter client cannot consume it.** `flutter_client/lib` contains no `auth/pair`,
  `pairing`, `ms_` or QR handling at all; its only identity is its own `dev_[0-9a-f]{16}` device id.
  The panel's copy — "A device token signs the Android app or Fire TV in…" — described a feature
  the client does not have.
- **Why the URL looked non-functional:** opened in the already-signed-in browser, it re-signs that
  browser in and redirects to `/`, which is visually a no-op. It only shows an effect on a different
  browser.

## 3. What was done

1. **Revoked the token exposed in the owner's screenshot** (`ms_bbd276…`, row id 40, label
   "test decice"): `revoked_at = 2026-10-23 23:20:59+05:30`. `POST /auth/pair` now answers **401**
   for it. The table holds **25 token rows, all revoked** — no live token was left behind.
2. **Removed the panel** from `AccountPage`: the form, the one-time token display, the token list
   with Revoke, and the "For Android TV & Fire TV" copy.
   `web/src/components/PairingQr.tsx` (`PairingQr` + `MintedTokenPanel`) was deleted with it.
   `docs/Current issues.md` → Issue 14 item 6 records the resolution.
3. **The QR sign-in card is the only pairing path.** It was already implemented
   (`QrSignInPanel` + `useQrSession`): 2-minute session, single-use confirmation on a signed-in
   phone, bound to the waiting device by its `secret_hash`.
4. **Tests:** `AccountPage.test.tsx` now pins that neither the panel nor any `/api/auth/tokens`
   request exists for signed-in or signed-out visitors, and that the QR card appears only when
   signed out. Web suite **311/311**, `oxlint` reports no new findings.

## 4. Why removal rather than "QR-only"

Hiding the URL and token while keeping the QR would still mint a **year-long, reusable,
password-equivalent link** — it would only be harder to copy. The QR sign-in card already covers
the only legitimate use case (signing another screen in) with a 2-minute, single-use,
phone-confirmed exchange. Nothing consumes `ms_…`, so the panel had no remaining user.

## 5. Exit criteria (all met)

- The Add-device panel is gone from `/account`; no minting UI exists.
- The account page makes no `/api/auth/tokens` request.
- The QR sign-in card remains, and renders only for signed-out visitors.
- The exposed token is revoked and refused by `/auth/pair` (401).
- `npm run test`, `npm run lint` and `npm run build` pass.

## 6. Left in place, deliberately

- The backend routes (`GET/POST /api/auth/tokens`, `DELETE /api/auth/tokens/{id}`, `/auth/pair`)
  and the client helpers in `web/src/lib/api/account.ts` remain. They are authenticated/admin
  surfaces and the client tests cover them; only the UI that encouraged their use is gone.
- Every token row is kept as an audit record (revoked, not deleted).
- The default lifetime is still 365 days in `create_token`; if the API is ever surfaced again it
  should mint short-lived, single-use links instead.

---

## 7. Issue 14 triage summary (updated)

| Issue | Fault | Status |
|---|---|---|
| 14.1 | Watch history not populated | ✅ **Fixed** — client id accepted, header wins over the stale cookie |
| 14.2 | Account icon missing across pages | ✅ **Closed** — misdiagnosis; one header avatar |
| 14.3 | Playback stuck at 0:00 | ✅ **Fixed** — `PlayerPage` source-attach effect |
| 14.4 | Unscannable QR in signed-in menu | ✅ **Option selected** — expand QR code container (option B) |
| 14.5 | Header sign-in → Google only | ✅ **Option selected** — QR on web/TV; disabled on phone |
| 14.6 | Add-device QR/URL/token confusion | ✅ **Fixed** — exposed token revoked, panel removed |

**Remaining:** 14.4 and 14.5 have a chosen option and await implementation.
