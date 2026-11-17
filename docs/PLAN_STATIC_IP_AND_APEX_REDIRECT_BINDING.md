# Implementation Plan: Static IP (IPoE) & Apex Domain Redirect Binding

**Date:** 2026-11-17  
**Target Host:** Windows 11 (`192.168.1.16`)  
**New Static IP:** `182.64.234.10` (Airtel IPoE)  
**Domains:** `media.anisparvez.in`, `anisparvez.in`, `www.anisparvez.in`  

---

## 1. Scope

### In Scope
1. **Cloudflare DNS Records:**
   - Update `media.anisparvez.in` A-record to `182.64.234.10` (`proxied: false`, TTL 300).
   - Update `anisparvez.in` (apex) A-records: replace stale GoDaddy parking IPs (`13.248.243.5`, `76.223.105.230`) with `182.64.234.10` (`proxied: false`, TTL 300).
   - Ensure `www.anisparvez.in` continues resolving to `anisparvez.in` (CNAME).
2. **Caddy Reverse Proxy Configuration (`E:\MediaServer\Caddyfile`):**
   - Retain existing `media.anisparvez.in` block routing to `127.0.0.1:8000`.
   - Add redirect block for `anisparvez.in, www.anisparvez.in` to redirect permanently (`redir https://media.anisparvez.in{uri} permanent`) using Cloudflare DNS-01 challenge for TLS certificate issuance.
3. **Service Validation & Reload:**
   - Validate configuration with `caddy_custom.exe validate`.
   - Restart `MediaServerCaddy` Windows service.
4. **End-to-End Verification:**
   - Verify DNS resolution via public resolvers (`1.1.1.1`, `8.8.8.8`).
   - Verify HTTPS on `https://media.anisparvez.in/health` returns `200 OK`.
   - Verify `https://anisparvez.in/` returns `308/301` redirect to `https://media.anisparvez.in/`.
   - External reachability verification via Jina external reader.

### Out of Scope / Deliberately Preserved
- No modifications to the Rust backend (`rust/`) or PostgreSQL (`MediaServerPG`).
- No changes to router NAT port forward table (`80`, `443`, `8000` already forward to `192.168.1.16`).
- No changes to mobile/TV API contracts.

---

## 2. Exit Criteria

- [ ] `media.anisparvez.in` resolves to `182.64.234.10` on `1.1.1.1`.
- [ ] `anisparvez.in` resolves to `182.64.234.10` on `1.1.1.1`.
- [ ] `curl.exe -i https://media.anisparvez.in/health` returns `HTTP/1.1 200 OK`.
- [ ] `curl.exe -i https://anisparvez.in/` returns `HTTP/1.1 308/301` with `Location: https://media.anisparvez.in/`.
- [ ] External fetch via `https://r.jina.ai/https://media.anisparvez.in/health` returns `200 OK` from external internet.
- [ ] `scripts/service_status.ps1` runs clean with all green checks.

---

## 3. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Caddy fails to obtain TLS certificate for `anisparvez.in` | Scoped Cloudflare API token in `Caddyfile` already has zone-wide DNS edit permissions on `anisparvez.in`. Validate with dry-run before restarting service. |
| DNS cache on local network holds old IP | Clear Windows DNS cache (`Clear-DnsClientCache`); verify with external resolvers (`1.1.1.1`). |
| Inbound traffic blocked on new IP | Verified prior to execution: `scripts/get-router-wan.ps1` confirmed ports 80 and 443 are already `REACHABLE` from outside on `182.64.234.10`. |

---

## 4. Open Decisions

1. **Apex DNS Proxying:**
   - Configured as `proxied: false` (direct ingress to Caddy), consistent with `media.anisparvez.in` for high-throughput streaming and clean end-to-end TLS certificate handling.
