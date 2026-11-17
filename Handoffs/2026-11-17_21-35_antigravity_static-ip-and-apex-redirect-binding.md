# Session Handoff: Static IP (IPoE) & Apex Domain Redirect Binding

**Date:** 2026-11-17 21:35 IST  
**Agent:** Antigravity  
**Branch:** `codex/container-phase-0`  
**Status:** Completed, Verified & Live  

---

## 1. Summary of Changes

1. **Airtel Static IP Allocation (IPoE):**
   - Airtel migrated the line from dynamic PPPoE to static IPoE with IPv4 address `182.64.234.10`.
   - Verified reboot persistence.
2. **Cloudflare DNS Updated:**
   - `media.anisparvez.in` -> `182.64.234.10` (`proxied: false`)
   - `anisparvez.in` -> `182.64.234.10` (`proxied: false`, removed GoDaddy parking records)
   - `www.anisparvez.in` -> `anisparvez.in` (`proxied: false`)
3. **Caddy Reverse Proxy & TLS:**
   - Added `anisparvez.in, www.anisparvez.in` block in `Caddyfile` with permanent redirect to `https://media.anisparvez.in{uri}`.
   - Synchronized `E:\MediaServer\Caddyfile` and `C:\MediaServer\Caddyfile`.
   - Restarted `MediaServerCaddy`. Automated DNS-01 challenge issued valid Let's Encrypt certificates for both domains.
4. **NAT Loopback:**
   - NAT loopback was enabled on the Zyxel router by the user, resolving hairpinning for LAN clients accessing the domain.
5. **Verification:**
   - `https://media.anisparvez.in/health` -> `200 OK`
   - `https://anisparvez.in/` -> `301 Moved Permanently` to `https://media.anisparvez.in/`
   - `https://www.anisparvez.in/` -> `301 Moved Permanently` to `https://media.anisparvez.in/`
   - Both internal and external access verified via `scripts/service_status.ps1` and Jina AI external fetcher.
