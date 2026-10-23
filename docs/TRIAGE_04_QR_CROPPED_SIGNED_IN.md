# Triage & Resolution — Issue 14.4: Cropped QR Code (Web)

**Date:** 2026-10-23 (IST 03:18), resolved 2026-10-24
**Issue:** [`docs/Current issues.md`](Current%20issues.md) → Issue 14, fault 4
**Branch:** `fix/issue-14-user-reported-faults`
**Status:** ✅ **Resolved 2026-10-24** — the reported panel was removed in 14.6; the only remaining QR reproduced the crop and is fixed.

---

## 1. Fault as reported

In the **signed-in** state, the QR code in the devices menu was **cropped / not fully displayed**, making it unscannable.

## 2. Which QR was reported?

The signed-in QR was `PairingQr` in the Add-device / *Devices & TV App Pairing* panel. That panel, its token list, and `web/src/components/PairingQr.tsx` were removed with the pairing-token retirement in `d6d6786` (Issue 14.6). Signed-in `/account` now renders the profile and **Active Session** only.

The only QR left is `QrSignInPanel`, rendered on `/account` only while signed out (`!authLoading && !authenticated`). It still reproduced the same class of defect, so it was fixed rather than simply closing 14.4 on the removal.

The Playwright probe asserts the signed-in state directly: no QR canvas, no `section[aria-label="QR Device Sign-In"]`, and **zero** `POST /api/auth/qr` requests.

## 3. Reproduction of the remaining QR

Probe: `web/e2e/qr-layout.spec.ts`. It mocks `/api/auth/me`, `POST /api/auth/qr`, the SSE wait stream, and `/api/transcodes`, so it creates no pair session and consumes no rate-limit budget.

The fixture is production-shaped: a 193-character pairing URL, 57 QR modules at error-correction level M.

| Viewport | Canvas | Card | Result |
| --- | --- | --- | --- |
| 390 px | 236 × 236 | 160 × 160 | clipped by 76 px |
| 768 px | 236 × 236 | 168.95 × 168.95 | clipped by 67 px |
| 1280 px | 236 × 236 | 220 × 220 | clipped by 16 px |

**Root cause:** `QRCode.toCanvas(..., { width: 0 })` does **not** mean "fill the element". `qrcode` treats `0` as falsy and falls back to its default scale of 4, producing a fixed **236 px** canvas and writing that size as an inline style. The inline style wins over the `w-full h-full` classes, and the card's `overflow-hidden` clips the overflow. The card was not being squeezed by flex; the bitmap was simply larger than the container.

## 4. Fix

In `web/src/components/QrSignInPanel.tsx`:

- The card now clamps to **220–240 px** (was 160–220 px), giving the 57-module payload a scannable minimum.
- The canvas carries `block max-w-full max-h-full`, so the bitmap is fitted to the card instead of clipping. The rounded `overflow-hidden` card is kept.
- The misleading `width: 0` option and its comment are gone; the library's default scale is used for a crisp module grid, and CSS supplies the fit.

Unchanged deliberately: QR payload and URL, white-on-dark colours, `margin: 1`, error-correction level `M`, the signed-out gating, the auth/session backend, and the TV/Flutter variants.

## 5. Verification

After the fix, the same probe reports:

| Viewport | Canvas | Card |
| --- | --- | --- |
| 390 px | 218 × 218 | 220 × 220 |
| 768 px | 218 × 218 | 220 × 220 |
| 1280 px | 236 × 236 | 240 × 240 |

The canvas is fully inside the card at every width, the card is at least 220 px square, and there is no horizontal page overflow. Screenshots were captured by the probe at each viewport.

A live check against the production server (`http://127.0.0.1:8000/account?intro=off`, real `/api/auth/me` and `POST /api/auth/qr`, one pair session) reproduced the same measurements — **218/220**, **218/220**, **236/240** — and reported `LIVE QR LAYOUT OK`. That proves the built CSS, not only the dev server. The plan's fallback of screenshot + bounding boxes was used; a physical phone scan was not performed in this session.

Also green:

- `npm run test` — **309/309**.
- `npm run lint` — no errors (pre-existing warnings only).
- `npm run build` — production build succeeds.

## 6. Files

- `web/src/components/QrSignInPanel.tsx` — container size and canvas fit.
- `web/e2e/qr-layout.spec.ts` — regression probe for 390/768/1280, plus the signed-in no-QR/no-request assertion.
- `docs/Current issues.md` — Issue 14.4 closed.
