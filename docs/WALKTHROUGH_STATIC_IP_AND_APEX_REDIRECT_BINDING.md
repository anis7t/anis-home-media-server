# Walkthrough: Static IP (IPoE) & Apex Domain Redirect Binding

**Date:** 2026-11-17 21:35 IST  
**Host:** Windows 11 (`192.168.1.16`)  
**New Static IP:** `182.64.234.10` (Airtel IPoE)  
**Domains Bound:** `media.anisparvez.in`, `anisparvez.in`, `www.anisparvez.in`  
**Status:** Completed, TLS Provisioned & Ingress Verified  

---

## 1. Overview & Context

Airtel successfully transitioned the fiber connection from PPPoE to IPoE, assigning a permanent static IPv4 address: **`182.64.234.10`**. The router retains this static lease across reboots.

The user approved the plan to bind `182.64.234.10` to `media.anisparvez.in` and configure apex `anisparvez.in` (and `www.anisparvez.in`) to redirect permanently to `https://media.anisparvez.in/`.

---

## 2. Changes Implemented

### A. Cloudflare DNS Synchronization
- **`media.anisparvez.in`:** Updated A-record from dynamic lease `223.235.84.147` to static IP `182.64.234.10` (`proxied: false`, `TTL: 300`).
- **`anisparvez.in` (Apex):** Replaced legacy GoDaddy parking A-records (`13.248.243.5` and `76.223.105.230`) with a single A-record pointing directly to `182.64.234.10` (`proxied: false`, `TTL: 300`).
- **`www.anisparvez.in`:** Configured CNAME pointing to `anisparvez.in` with `proxied: false`.

### B. Caddy Reverse Proxy & Redirect Block
Updated `E:\MediaServer\Caddyfile` and `C:\MediaServer\Caddyfile`:
```caddy
media.anisparvez.in {
    log {
        output file E:/MediaServer/logs/caddy_access.log {
            roll_size 10mb
            roll_keep 3
        }
    }
    tls {
        dns cloudflare <CLOUDFLARE_API_TOKEN>
    }
    reverse_proxy 127.0.0.1:8000
}

anisparvez.in, www.anisparvez.in {
    tls {
        dns cloudflare <CLOUDFLARE_API_TOKEN>
    }
    redir https://media.anisparvez.in{uri} permanent
}
```

### C. Service Restart & Automated TLS Certificate Issuance
- Authored [scripts/restart_caddy_service.bat](file:///e:/MediaServer/scripts/restart_caddy_service.bat).
- Restarted `MediaServerCaddy` Windows service.
- Caddy executed automated DNS-01 ACME challenges via Cloudflare API for `anisparvez.in` and `www.anisparvez.in`.
- Let's Encrypt certificates were successfully downloaded, verified, and loaded into Caddy.

### D. Router NAT Loopback
- User enabled NAT Loopback in the Zyxel ONT settings, allowing LAN devices to reach `https://media.anisparvez.in` and `https://anisparvez.in` via the WAN IP without hairpin interception.

---

## 3. Verification & Evidence

### A. Apex Domain HTTPS Redirect
```bash
curl.exe -i "https://anisparvez.in/"
```
```http
HTTP/1.1 301 Moved Permanently
Alt-Svc: h3=":443"; ma=2592000
Location: https://media.anisparvez.in/
Server: Caddy
Date: Tue, 17 Nov 2026 16:01:52 GMT
Content-Length: 0
```

### B. Subdomain `www.anisparvez.in` HTTPS Redirect
```bash
curl.exe -i "https://www.anisparvez.in/"
```
```http
HTTP/1.1 301 Moved Permanently
Alt-Svc: h3=":443"; ma=2592000
Location: https://media.anisparvez.in/
Server: Caddy
Date: Tue, 17 Nov 2026 16:01:59 GMT
Content-Length: 0
```

### C. Media Server Health & Direct Ingress
```bash
curl.exe -i "https://media.anisparvez.in/health"
```
```http
HTTP/1.1 200 OK
Alt-Svc: h3=":443"; ma=2592000
Content-Length: 83
Content-Type: application/json
Date: Tue, 17 Nov 2026 16:02:05 GMT
Via: 1.1 Caddy

{"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}
```

### D. External Internet Probes (Jina AI External Reader)
- **`https://media.anisparvez.in/health`:** External fetch returns `200 OK` with JSON health payload.
- **`https://anisparvez.in/`:** External fetch follows 301 redirect to `https://media.anisparvez.in/` and renders the media server library with full catalog metadata.

### E. Service Status Suite (`scripts/service_status.ps1`)
```text
[1/5] Windows Services: MediaServerCaddy, MediaServerPG, MediaServerRust [All Running / Automatic]
[2/5] Port Listeners Check:
  Rust/Axum (Port 8000): Listening by media-server-api (PID: 8492)
  Postgres  (Port 5432): Listening by postgres (PID: 7560)
  Caddy     (Port 443) : Listening by caddy_custom (PID: 7708)
  Caddy     (Port 80)  : Listening (HTTP -> HTTPS redirect)
[3/5] HTTP Connectivity:
  Local Loopback (http://127.0.0.1:8000/health): OK
  LAN Ingress    (http://192.168.1.16:8000/health): OK
  Local SPA      (http://127.0.0.1:8000/): 200 OK
  Local API      (http://127.0.0.1:8000/api/movies): 200 OK
  Domain HTTPS   (https://media.anisparvez.in/health): OK [TLS Valid, Engine: rust]
```
