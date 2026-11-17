# Walkthrough: Post-Reboot Service Diagnostic & Cloudflare DNS Restoration

**Date:** 2026-11-16 04:50 IST  
**Host:** Windows 11 (`192.168.1.16`)  
**Domain:** `media.anisparvez.in`  
**Status:** Inactive Domain Identified, Cloudflare DNS Updated & Ingress Verified  

---

## 1. Executive Summary & Root Cause Analysis

Following a system / gateway reboot 24–48 hours ago, `media.anisparvez.in` became inaccessible externally.

### Root Cause
1. **Dynamic PPPoE WAN IP Shift:**
   - The Airtel Xstream Fiber connection in Bihar operates on PPPoE. When the gateway/host restarted, Airtel's BNG assigned a new public egress IP: **`223.235.84.147`**.
   - Previously (from the Nov 14 session), the public egress IP was **`223.235.84.216`**.
2. **Stale Cloudflare DNS Record:**
   - Cloudflare DNS for `media.anisparvez.in` was configured with an unproxied A-record (`proxied: false`) pointing to the old IP `223.235.84.216`.
   - External requests to `media.anisparvez.in` were directed to `223.235.84.216`, resulting in connection timeouts (`curl: (28) Connection timed out`).
3. **What Survived the Restart (100% Operational):**
   - **`MediaServerRust` (Axum backend on `:8000`):** Started automatically, healthy.
   - **`MediaServerCaddy` (Caddy reverse proxy on `:80`/`:443`):** Started automatically, healthy, TLS certificate active.
   - **`MediaServerPG` (PostgreSQL on `:5432`):** Started automatically, healthy.
   - **Host Static IP:** `192.168.1.16` on `Ethernet` retained via Zyxel static DHCP reservation.
   - **Gateway Port Forwarding:** Ports `443`, `80`, and `8000` remained mapped to `192.168.1.16`.
4. **Regarding Apex Domain `anisparvez.in`:**
   - `anisparvez.in` is configured with A-records pointing to GoDaddy parking servers (`13.248.243.5` and `76.223.105.230`) proxied through Cloudflare. The media server is hosted on `media.anisparvez.in`.

---

## 2. Actions Taken

1. **System & Ingress Diagnostics:**
   - Verified service status: `MediaServerCaddy`, `MediaServerPG`, and `MediaServerRust` all `Running` / `Automatic`.
   - Detected current public IP: `223.235.84.147`.
   - Tested WAN port reachability via `scripts/get-router-wan.ps1`: Ports 80 and 443 confirmed `REACHABLE` from external vantage point.
2. **Cloudflare DNS Update:**
   - Executed `scripts/update_cloudflare_dns.ps1`.
   - Updated `media.anisparvez.in` A-record from `223.235.84.216` to `223.235.84.147` (`proxied: false`, `TTL: 300`).
3. **DNS Propagation & Cache Flush:**
   - Flushed local Windows DNS client cache (`Clear-DnsClientCache`).
   - Confirmed public resolvers (`1.1.1.1` and `8.8.8.8`) resolve `media.anisparvez.in` to `223.235.84.147`.

---

## 3. Verification & Live Health Checks

### A. External Ingress Probing (Jina AI External Reader)
```text
URL: https://media.anisparvez.in/health
Result: {"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}
Status: 200 OK
```

### B. Local HTTPS Resolution
```bash
curl.exe -i "https://media.anisparvez.in/health"
```
```http
HTTP/1.1 200 OK
Alt-Svc: h3=":443"; ma=2592000
Content-Length: 83
Content-Type: application/json
Date: Sun, 15 Nov 2026 23:19:34 GMT
Via: 1.1 Caddy

{"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}
```

### C. Repository Service Status Suite (`scripts/service_status.ps1`)
```text
[1/5] Windows Services: MediaServerCaddy, MediaServerPG, MediaServerRust [All Running / Automatic]
[2/5] Port Listeners: Rust :8000, Postgres :5432, Caddy :443/:80 [All Active]
[3/5] HTTP Connectivity:
  Local Loopback (http://127.0.0.1:8000/health): OK
  LAN Ingress    (http://192.168.1.16:8000/health): OK
  Local SPA      (http://127.0.0.1:8000/): 200 OK
  Local API      (http://127.0.0.1:8000/api/movies): 200 OK
  Domain HTTPS   (https://media.anisparvez.in/health): OK [TLS Valid, Engine: rust]
```
