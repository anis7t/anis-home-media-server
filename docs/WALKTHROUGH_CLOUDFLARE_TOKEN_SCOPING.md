# Walkthrough — Sub-item 3.2: Cloudflare API Token Scoping & Verification

- **Date:** 2026-10-24
- **Author:** Antigravity (Advanced Agentic Pair Programmer)
- **Status:** ✅ **COMPLETED & VERIFIED**
- **Plan Reference:** [`docs/PLAN_CLOUDFLARE_TOKEN_SCOPING.md`](PLAN_CLOUDFLARE_TOKEN_SCOPING.md)

---

## 1. Executive Summary

Sub-item 3.2 of Category 3 (Owner Security & Credential Actions) has been fully implemented, audited, and verified. 

The audit proved that the active Cloudflare API token used for automated Let's Encrypt DNS-01 ACME challenge certificates is **already strictly isolated to the principle of least privilege**:
- It has **zero access to User Profile or account billing details** (`403 Forbidden`).
- It has **zero access to Account Members or organization management** (`403 Forbidden`).
- Its permissions are **confined strictly to the single zone `anisparvez.in`** with `#dns_records:edit`, `#dns_records:read`, and `#zone:read`.
- An automated audit tool [`scripts/verify_cloudflare_token.ps1`](../scripts/verify_cloudflare_token.ps1) has been created to enable continuous zero-trust validation on demand.
- [`Caddyfile.template`](../Caddyfile.template) has been updated with explicit token generation instructions and environment variable guidance.

---

## 2. Changes & Deliverables

### A. Automated Audit Script (`scripts/verify_cloudflare_token.ps1`)
Created [`scripts/verify_cloudflare_token.ps1`](../scripts/verify_cloudflare_token.ps1):
- Automatically resolves the token from `E:\MediaServer\Caddyfile` or `$env:CLOUDFLARE_API_TOKEN`.
- Queries Cloudflare's `/user/tokens/verify` endpoint to assert active token status.
- Queries `/zones` to confirm the token is scoped strictly to `anisparvez.in` with `#dns_records:edit`, `#dns_records:read`, and `#zone:read`.
- Probes `/user` and `/accounts/{id}/members` to assert that elevated administrative capabilities are blocked (`403 Forbidden`).
- Renders an automated status table with green/red indicator logging.

### B. Updated Template (`Caddyfile.template`)
Updated [`Caddyfile.template`](../Caddyfile.template) to document:
- The exact Cloudflare dashboard custom token path: `My Profile -> API Tokens -> Create Custom Token`.
- The exact permissions required: `Zone:DNS:Edit` and `Zone:Zone:Read`.
- The zone restriction: `Include:Specific zone:anisparvez.in`.
- Support for `{env.CLOUDFLARE_API_TOKEN}` environment variable substitution.
- A direct pointer to `scripts/verify_cloudflare_token.ps1` for auditing.

---

## 3. Verification & Audit Results

### 1. Automated Scoping Audit Output
Running `powershell -ExecutionPolicy Bypass -File .\scripts\verify_cloudflare_token.ps1`:
```text
====================================================
     Cloudflare API Token Least-Privilege Audit     
====================================================
Extracted token from E:\MediaServer\Caddyfile
Auditing Token: cfut_Kk3...7aff

[1/4] Probing /user/tokens/verify ...
  [+] Token Status: ACTIVE (Token ID: 23fca400a8bfee7432587684c67ce22e)
[2/4] Probing /zones for DNS Scoping ...
  [*] Accessible Zones Count: 1
  [+] Target Zone 'anisparvez.in' Found (ID: 90470dd26c12404f8b386c6a4c6687a3)
      Granted Permissions: #dns_records:edit, #dns_records:read, #zone:read
  [+] Required DNS-01 Permissions (#dns_records:edit, #dns_records:read, #zone:read): PRESENT
  [+] Scoping Isolation: Confined strictly to 1 zone (No broad multi-zone exposure)
[3/4] Probing Least-Privilege Boundary: User Profile (/user) ...
  [+] Access to /user DENIED (403) - Correctly isolated.
[4/4] Probing Least-Privilege Boundary: Account Members (/accounts/members) ...
  [+] Access to /accounts/members DENIED (403) - Correctly isolated.

====================================================
                 AUDIT SUMMARY                      
====================================================
  Token Status:       ACTIVE
  Target Zone:        anisparvez.in (Isolated to 1 zone)
  Required Rights:    #dns_records:edit, #dns_records:read, #zone:read
  User Profile Scope: DENIED (Protected)
  Account Admin Scope:DENIED (Protected)
  Overall Evaluation: LEAST-PRIVILEGE COMPLIANT
====================================================
```

### 2. Service Health & Ingress Validation
Running `scripts/rust_service_status.ps1`:
- `MediaServerCaddy` (NSSM Windows Service): **Running** on Port 443 & 80.
- ACME renewal check: Caddy successfully interacts with Let's Encrypt / Cloudflare API for automated cert renewal.
- Ingress: `https://media.anisparvez.in/health` returns `200 OK` (`[TLS Valid, Engine: rust]`).

---

## 4. Next Steps

Sub-item 3.2 is complete and verified. The remaining sub-item in Category 3 is:
- **Sub-item 3.3: Google Sign-In Post-Fix Verification** — End-to-end browser verification of Google sign-in with `anis7t@gmail.com` confirming admin role landing.
