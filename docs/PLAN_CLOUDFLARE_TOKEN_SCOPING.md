# Implementation Plan — Sub-item 3.2: Cloudflare API Token Scoping & Verification

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** 📋 **PENDING USER APPROVAL**
- **Target Tracking:** Category 3.2 in [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md), [`docs/Current issues.md`](Current%20issues.md)

---

## 1. Context & Background

To secure inbound remote access (`https://media.anisparvez.in`), Caddy uses the ACME DNS-01 challenge via the `caddy-dns/cloudflare` plugin to automatically obtain and renew wildcard/subdomain Let's Encrypt certificates without requiring open ISP port 80.

To adhere to the principle of least privilege:
1. The API token must **not** possess broad account-level or user-level administrative privileges (e.g. Account Administrator, User Profile, Billing, or Cloudflare Tunnel management).
2. It must be strictly restricted to:
   - Permissions: `Zone:DNS:Edit` and `Zone:Zone:Read`.
   - Resource Scope: Limited to the single specific zone `anisparvez.in`.
3. The repository template [`Caddyfile.template`](../Caddyfile.template) currently contains no permission documentation or environment variable options.
4. An automated audit tool is needed to allow the operator to verify that the active token satisfies all least-privilege constraints without guessing.

---

## 2. Scope

### In Scope
- **Automated Verification Script (`scripts/verify_cloudflare_token.ps1`):**
  - Verify token validity against `https://api.cloudflare.com/client/v4/user/tokens/verify`.
  - Check zone scoping: confirm access to `anisparvez.in` with `#dns_records:edit`, `#dns_records:read`, and `#zone:read`.
  - Enforce least privilege: assert that user profile (`/user`) and account memberships (`/accounts/{id}/members`) are strictly forbidden (`403` / `401`).
- **Template & Documentation Hardening:**
  - Update [`Caddyfile.template`](../Caddyfile.template) with explicit least-privilege token creation steps and support for `{env.CLOUDFLARE_API_TOKEN}`.
  - Update [`docs/WINDOWS_SETUP.md`](WINDOWS_SETUP.md) and [`docs/PROJECT_STATUS.md`](PROJECT_STATUS.md) documenting token scoping specifications.
- **Service & Ingress Validation:**
  - Verify that Caddy ACME renewal telemetry remains 100% operational with the scoped token.
  - Verify HTTPS ingress on `https://media.anisparvez.in/health`.

### Out of Scope
- Modifying Caddy's compiled binary (`caddy_custom.exe`).
- Changing router port forwarding rules (Ports 443/80 remain configured).
- Changing Cloudflare nameservers or root DNS records.

---

## 3. Implementation Steps

### Step 1: Create Automated Token Scoping Audit Utility (`scripts/verify_cloudflare_token.ps1`)
1. Implement a PowerShell utility that:
   - Extracts the token from `E:\MediaServer\Caddyfile` (or accepts `-Token <string>` / `$env:CLOUDFLARE_API_TOKEN`).
   - Queries Cloudflare's `/user/tokens/verify` endpoint.
   - Inspects `/zones` to ensure only `anisparvez.in` is exposed and permissions are limited to DNS edit/read.
   - Probes forbidden endpoints (`/user`, `/accounts/{id}/members`) to prove non-proliferation.
   - Outputs an audit summary table with green/red status indicators.

### Step 2: Update Repository Template (`Caddyfile.template`)
1. Add structured comments in `Caddyfile.template` detailing the exact token creation settings:
   - Template: Custom Token
   - Token Name: `MediaServer Caddy DNS-01`
   - Permissions: `Zone` -> `DNS` -> `Edit`, `Zone` -> `Zone` -> `Read`
   - Zone Resources: `Include` -> `Specific zone` -> `anisparvez.in`
2. Document support for `{env.CLOUDFLARE_API_TOKEN}` environment variable substitution.

### Step 3: Run Audit & Verify Live Token
1. Execute `scripts/verify_cloudflare_token.ps1` against the live production Caddy configuration.
2. Verify that:
   - Token status is `active`.
   - Zone is strictly limited to `anisparvez.in`.
   - Elevated scopes are denied.
3. Check `scripts/rust_service_status.ps1` to verify `MediaServerCaddy` status and certificate renewal check.

### Step 4: Documentation & Walkthrough
1. Update `docs/PROJECT_STATUS.md` and `docs/Current issues.md` recording Sub-item 3.2 as verified.
2. Author completion walkthrough [`docs/WALKTHROUGH_CLOUDFLARE_TOKEN_SCOPING.md`](WALKTHROUGH_CLOUDFLARE_TOKEN_SCOPING.md).

---

## 4. Exit Criteria

- [ ] `scripts/verify_cloudflare_token.ps1` runs and proves the active token satisfies all least-privilege scoping rules.
- [ ] Account-wide and user-profile access are verified denied.
- [ ] `Caddyfile.template` is updated with complete, clear instructions for generating scoped DNS tokens.
- [ ] Production service `MediaServerCaddy` and HTTPS domain `https://media.anisparvez.in/health` verified healthy.
- [ ] Full walkthrough document delivered.

---

## 5. Risks & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Overly restrictive token | Let's Encrypt DNS-01 challenge fails to create `_acme-challenge` TXT records | Verify that `#dns_records:edit` permission is present; Caddy logs confirm successful ACME renewals. |
| Token expiration / invalidation | TLS certificates expire without renewal | The script checks `/user/tokens/verify` and reports token active status and expiry if set. |
| Plaintext secret exposure in git | Leaked API token | `Caddyfile` is strictly in `.gitignore`; `scripts/verify_cloudflare_token.ps1` masks the token in console output. |

---

## 6. Open Decisions for User

1. **Token Delivery in Caddyfile:**
   - **Option A (Current & Recommended):** Keep the scoped token directly inside `E:\MediaServer\Caddyfile` (which is already protected by `.gitignore` and NTFS ACLs on the host machine) with `Caddyfile.template` fully documenting the scoping.
   - **Option B (Environment Variable):** Migrate Caddyfile to `dns cloudflare {env.CLOUDFLARE_API_TOKEN}`, storing the token in the NSSM service environment or system environment variables.
