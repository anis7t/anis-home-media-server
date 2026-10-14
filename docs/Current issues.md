# Resolution Log — Current Issues (October 2026)

All 7 architectural, authentication, telemetry, and performance issues recorded in this document have been systematically addressed, tested, and resolved across 4 planned implementation phases.

---

### Issue 1: Manage Page Loading Latency & Premature "On-Demand HLS" Badges
- **Reported:** *"The manage page takes a while to load...but there's no loading indication... It just wrongly shows the files as on demand hls whereas they are already transcoded...And it stays like this for around 5-20 secs...then updates."*
- **Resolution (Phase 1):**
  - **Fast Synchronous Probing:** Replaced synchronous FFmpeg/ffprobe inspection and sluggish directory crawling with instant filesystem probing (`probe_hls_cache_instant()`) in `app/services/media_service.py`. Checks `.archive` and primary media roots synchronously for pre-existing `master.m3u8` playlists with zero CPU overhead.
  - **Immediate Metadata Hydration:** `ManagePage.tsx` loads the movie inventory in `< 100ms`, displaying real-time accurate badges (*Cached HLS* vs *Direct Play* vs *On-Demand HLS*) immediately without 5–20s delay.
  - **Skeleton Loading & Telemetry Indicators:** Added rich obsidian animated skeleton placeholders for the Storage Pool Hud and audit sections during initial load.

---

### Issue 2: `AUTH: enforcement is OFF (MEDIA_SERVER_AUTH unset)` Clarification
- **Reported:** *`"AUTH: enforcement is OFF (MEDIA_SERVER_AUTH unset)."` Why is it unset? is that a security concern?*
- **Resolution (Phase 2):**
  - **Architecture Clarification:** Explained the deliberate single-household security model. When `MEDIA_SERVER_AUTH` is unset (default), open-door Guest Mode allows family members to stream, browse, and adjust subtitles on local LAN/smart TVs without typing credentials. Destructive actions (deletions, retention policies, uploads) remain strictly protected by the Admin PIN and Google Admin sessions.
  - **Enforcement Mode:** Documented that setting `MEDIA_SERVER_AUTH=1` activates strict Zero-Trust mode, requiring every caller to present an authorized Google session or bearer token.
  - **In-App & Offline Documentation:** Fully documented in `docs/MANUAL.md` and `docs/PROJECT_STATUS.md`.

---

### Issue 3: Devices / Account Page Unsigned-In Guest State & Sign-Out Clarity
- **Reported:** *In the devices page in unsigned-in state, it says signed in as unknown and also there is a sign out option there. WHat happens when you sign out?*
- **Resolution (Phase 2):**
  - **Account & Devices Separation:** Re-routed device pairing and session identity to `/account`, reserving `/devices` purely for client presence and network telemetry.
  - **Guest Mode Card:** Replaced confusing "Signed in as Unknown" with an informative obsidian **Guest Mode** card explaining local hardware device identification (`ms_device_id`).
  - **Conditional Sign-Out:** When unauthenticated, the confusing "Sign Out" button is completely removed. In its place, a prominent **"Sign in with Google"** button allows upgrading to a user-scoped session.

---

### Issue 4: Device Pairing Mechanism, Tokens & Watch History
- **Reported:** *In the devices page, there is a section to pair a device but it also says in browser it's not required. And the whole point of pairing a device is to have a watch history, resume points and other settings without typing password. WHere can one see their watch history? Also the mechanism is confusing. How would it know which device is to be paired by just entering a name? Like how adding a device would provide a token and if i have the token, i can pair my device. What is purpose of google sign in then? doesn't it preserve settings account wise and then on different devices with the same account can have device name for distinction?*
- **Resolution (Phase 3):**
  - **15-Minute Pairing Token Engine:** Added `POST /api/auth/pairing-token/mint` and `POST /api/auth/pairing-token/claim` to `app/routes/auth.py`. Users enter a friendly name on `/account` (phone/PC) to generate an ephemeral 6-character code (e.g. `K9X2P4`). Entering this code on Fire TV or a secondary browser mints a 1-year cryptographically secure device bearer token (`ms_device_token`).
  - **Interactive Watch History Drawer:** Added `POST /api/progress` watch reporting and a sliding obsidian Watch History Drawer on `/account`. Displays movie posters, timestamps, completion percentages, resume action buttons, and a **Clear All History** option.
  - **Google Account Association:** User-scoped progress and paired device tokens are tied to the Google account, syncing watch state across all authorized household screens.

---

### Issue 5: Admin 403 on Add Device (Admin PIN Token Minting)
- **Reported:** *In the devices page, when I(admin) try to add a device, I get 403'd.*
- **Resolution (Phase 3):**
  - **Admin PIN Support in Token Minting:** Updated `mint_pairing_token()` in `app/routes/auth.py` and `account.ts` to accept `X-Admin-Pin` headers and evaluate `is_admin_authorized()`.
  - **Session Persistence:** When unlocked with the Admin PIN, administrators can mint pairing tokens and manage devices without encountering 403 authorization barriers.

---

### Issue 6: Non-Admin Signed-In Users Adding Devices in Their Own Scope
- **Reported:** *Also, why can't other user add devices? only admin can? Other signed in user should also be able to do that in their own scope.*
- **Resolution (Phase 3):**
  - **User-Scoped Device Pairing:** Removed `@require_admin` from pairing token creation and device listing. Any authenticated user (with role `viewer` or `admin`) can mint pairing tokens and pair smart TVs/clients within their own user account scope.
  - **Token Ownership Verification:** Verified by unit tests in `tests/test_auth_tokens.py` (`test_viewer_can_mint_pairing_token_in_own_scope`).

---

### Issue 7: Admin-Only Gating for Manage Page, Fleet Presence Privacy Scoping & Route Hardening
- **Reported:** *And I think the manage page and client presence telementry which shows all users device details such as IPetc should be gated only for admins. Look for other places in the codebase if there are other such pages which should be gated for admins only. Maybe only the devices in their own user scope should be visible to a user?*
- **Resolution (Phase 4):**
  - **Manage Page Admin Gate (`ManagePage.tsx`):** If caller is not authorized as an administrator (`!isAdmin`), backend settings and storage audits are not fetched. Renders a rich obsidian Access-Denied card with ambient radial lighting, glowing pulse shield, 4 capability overview cards, and a portaled Admin PIN unlock dialog.
  - **Client Presence Telemetry Privacy Scoping (`app/routes/api.py` & `DevicesPage.tsx`):** `GET /api/devices` filters the device list strictly to the caller's current device (`is_current == True`) when unauthorized as admin, concealing other household IP addresses and active sessions. Displays an informative amber privacy scoping banner with an **"Unlock Fleet Telemetry"** button.
  - **Device Rename / Delete Route Protection:** `POST /api/devices/rename` and `POST /api/devices/delete` reject attempts by non-admins to alter or forget any device other than their own current device (`device_id == current_device_id()`).
  - **Backend Endpoint Hardening:** Added admin authorization requirements to `POST /api/scan`, `POST /upload`, `POST /upload/chunk/init`, and `GET /api/storage/audit`.
