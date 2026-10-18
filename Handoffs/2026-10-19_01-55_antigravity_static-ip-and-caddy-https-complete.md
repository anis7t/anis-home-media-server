# Handoff: Static IP Migration & Caddy Let's Encrypt HTTPS Setup Complete

**Date / Time (IST):** 2026-10-19 01:55  
**Agent:** Antigravity  
**Branch:** `feat/active-transcoding-dashboard`  
**Deliverables Documented:** [`docs/STATIC_IP_MIGRATION_WALKTHROUGH.md`](../docs/STATIC_IP_MIGRATION_WALKTHROUGH.md), [`docs/CADDY_HTTPS_WALKTHROUGH.md`](../docs/CADDY_HTTPS_WALKTHROUGH.md)

---

## 1. Summary of Completed Work

### A. Static IP & CGNAT Exit
1. **Public IP Allotted:** The server was allocated a direct public IP (`122.163.124.18`) on Airtel Xstream Fiber.
2. **CGNAT Cleared:** Router reboot forced the WAN PPPoE link (`ppp111`) to release the old CGNAT address (`100.134.37.148`) and acquire direct public IP `122.163.124.18`. Verified 1:1 match against external egress (`api.ipify.org`).
3. **Cloudflared Decommissioned:**
   - Stopped and deleted the `Cloudflared` Windows Service via [`scripts/remove_cloudflared_service.bat`](../scripts/remove_cloudflared_service.bat).
   - Switched Cloudflare DNS `media.anisparvez.in` to DNS-only (Grey Cloud) `A` record pointing to `122.163.124.18`.

### B. Router Port Forwarding (Zyxel AOT5222ZY)
Configured and persisted in router NVRAM (`portForwarding.cgi`):
- Port `443` (TCP) $\rightarrow$ `192.168.1.16:443` (HTTPS)
- Port `80` (TCP) $\rightarrow$ `192.168.1.16:80` (HTTP Redirect)
- Port `8000` (TCP) $\rightarrow$ `192.168.1.16:8000` (Direct Axum)

### C. Caddy Reverse Proxy & Let's Encrypt TLS 1.3
1. **Binary Location:** `E:\MediaServer\bin\caddy_custom.exe` (built with `dns.providers.cloudflare`).
2. **Service Name:** `MediaServerCaddy` registered via NSSM (`E:\MediaServer\bin\nssm.exe`) as an automatic persistent Windows Service.
3. **Automated SSL:** Let's Encrypt TLS 1.3 certificate obtained via automated DNS-01 ACME challenge using Cloudflare DNS API (no open inbound port 80 required for cert issuance).
4. **Clean URLs:** Accessible globally at `https://media.anisparvez.in` (zero port numbers needed).
5. **Auto Redirect:** Port 80 automatically 308-redirects to `https://media.anisparvez.in`.

---

## 2. Ingress & Playback Verification

1. **4K HDR Video Playback Test (*Ghost in the Cell*):**
   - Streamed over public internet: React 19 SPA, HLS fMP4 master playlist, initialization segments (`init_chunk_0.mp4`), and `.m4s` chunks delivered cleanly over HTTPS.
2. **Multi-Service Health:**
   - `MediaServerRust` (Axum `:8000`), `MediaServerPG` (PostgreSQL `:5432`), and `MediaServerCaddy` (HTTPS `:443` & HTTP `:80`) all running automatically. Verified via [`scripts/service_status.ps1`](../scripts/service_status.ps1).

---

## 3. Persistent Operational Scripts

* [`scripts/install_caddy_service.bat`](../scripts/install_caddy_service.bat) / [`.ps1`](../scripts/install_caddy_service.ps1): Installs firewall rules and registers/starts `MediaServerCaddy`.
* [`scripts/remove_cloudflared_service.bat`](../scripts/remove_cloudflared_service.bat) / [`.ps1`](../scripts/remove_cloudflared_service.ps1): Decommissions Cloudflare tunnel.
* [`scripts/service_status.ps1`](../scripts/service_status.ps1): Full health check of all 3 services, port listeners, and HTTPS ingress.
