# Implementation Plan: Migration from Cloudflare Tunnel to Direct Static IP

**Document Path:** `docs/STATIC_IP_MIGRATION_PLAN.md`  
**Date:** 2026-10-19  
**Status:** Pending User Approval  

---

## 1. Executive Summary & Context

The media server currently exposes public access (`media.anisparvez.in`) via an outbound Cloudflare Named Tunnel (`cloudflared` Windows Service). With a dedicated static public IPv4 address now allotted to the host connection (detected outbound IP: `106.222.224.208`), the server can transition to direct public ingress via the static IP, eliminating the dependency on the `cloudflared` tunnel client.

Per user confirmation:
1. The domain `media.anisparvez.in` will point to the static IP so existing URLs, browser bookmarks, and mobile/Android TV Flutter client defaults remain 100% intact.
2. Step-by-step router port forwarding and firewall guidance will be provided.
3. The `cloudflared` Windows Service will be safely decommissioned and removed.

---

## 2. Scope

### In Scope
- **Router & Network Ingress Configuration Guidance:** Detailed step-by-step instructions for port forwarding (WAN $\rightarrow$ LAN `192.168.1.16:8000`) and DHCP address reservation on the home gateway/router.
- **Windows Firewall Verification:** Ensure Windows Defender Firewall allows inbound TCP connections on port `8000`.
- **DNS Record Alignment:** Guidance and verification for updating `media.anisparvez.in` DNS from tunnel CNAME to static IP A-record.
- **Cloudflared Service Decommissioning:** Graceful stop, service deletion (`sc.exe delete Cloudflared`), and disabling the background daemon.
- **Diagnostic Scripts Update:** Update `scripts/service_status.ps1` to remove `Cloudflared` from the services array and probe direct static IP / domain health.
- **Documentation & Status Update:** Update `README.md`, `docs/PROJECT_STATUS.md`, and system reference docs to reflect the new static IP network topology.

### Out of Scope / Deliberately Preserved
- **Rust Backend Server (`rust/src/`):** No port or host code changes needed. Rust Axum already binds to `0.0.0.0:8000` (`rust/src/config.rs:64`), which already accepts LAN and WAN forwarded traffic.
- **Database & Services:** PostgreSQL 18.4 (`MediaServerPG`) and transcode pipeline remain unchanged on ports 5432 and GPU queues.
- **Client API Contracts:** Flutter and React client routes (`/api/*`, `/media/*`, `/health`) remain identical.

---

## 3. Architecture Transition

### Previous Topology
```
Internet Client
  └──> media.anisparvez.in (Cloudflare Edge)
        └──> Named Cloudflare Tunnel (QUIC/HTTP2 outbound)
              └──> C:\Cloudflared\cloudflared.exe (Windows Service)
                    └──> http://127.0.0.1:8000 (Rust Axum)
```

### New Topology
```
Internet Client
  └──> media.anisparvez.in (DNS A-record: 106.222.224.208)
        └──> Home Router / Gateway WAN (Port 8000 or 443)
              └──> NAT Port Forwarding: 192.168.1.16:8000
                    └──> http://0.0.0.0:8000 (MediaServerRust Axum)
```

---

## 4. Work Breakdown & Implementation Slices

### Phase 1: Router Port Forwarding & Local Firewall Setup (User Action + Verification)
1. **Router DHCP Reservation:** Ensure the server PC (`Ethernet`, MAC address) is bound to `192.168.1.16` so the internal IP never changes upon reboot.
2. **Router Port Forwarding Rule:**
   - **Service Name:** `MediaServer`
   - **Protocol:** `TCP`
   - **External (WAN) Port:** `8000` (or external `8000` forwarded to internal `8000`)
   - **Internal IP:** `192.168.1.16`
   - **Internal Port:** `8000`
   - **Status:** Enabled
3. **Windows Firewall Rule:** Verify or create an inbound rule in Windows Defender Firewall for TCP port 8000:
   ```powershell
   New-NetFirewallRule -DisplayName "MediaServer Rust Axum (Port 8000)" -Direction Inbound -LocalPort 8000 -Protocol TCP -Action Allow
   ```

### Phase 2: DNS & Cloudflare Configuration
1. Open Cloudflare DNS Management for `anisparvez.in`.
2. Locate the record for `media.anisparvez.in`:
   - Delete or edit the existing `CNAME` pointing to `dccb29d4-1a41-4452-819e-34df85d6338d.cfargotunnel.com`.
   - Add an **A Record**:
     - **Type:** `A`
     - **Name:** `media`
     - **IPv4 address:** `106.222.224.208` (or the user-specified static IP)
     - **Proxy status:**
       - *Option A (Proxied - Orange Cloud):* Keeps Cloudflare free SSL termination at the edge. **Note:** In Cloudflare Free, proxied HTTPS works on ports 443, 2053, 2083, 2087, 2096, 8443. If external port 8000 is used directly without port translation, Cloudflare Proxy must be disabled (DNS Only - Grey Cloud), OR the router can map external port 443 / 8443 $\rightarrow$ internal 8000.
       - *Option B (DNS Only - Grey Cloud):* Cloudflare acts strictly as DNS. Traffic directly hits the static IP on port 8000 (`http://media.anisparvez.in:8000`).

### Phase 3: Cloudflared Windows Service Decommissioning
1. Stop the running service:
   ```powershell
   Stop-Service -Name "Cloudflared" -Force -ErrorAction SilentlyContinue
   ```
2. Unregister / delete the Windows Service:
   ```powershell
   sc.exe delete "Cloudflared"
   ```
3. Archive or delete tunnel configuration in `C:\Users\anis7\.cloudflared\` and logs in `C:\Cloudflared\`.

### Phase 4: Diagnostic Script & Tooling Updates
1. Update `scripts/service_status.ps1`:
   - Remove `"Cloudflared"` from `$services = Get-Service -Name "MediaServerRust", "MediaServerPG"`
   - Update probe section: Test `http://192.168.1.16:8000/health` and WAN URL probe instead of tunnel-specific messaging.
2. Execute `scripts/service_status.ps1` to verify clean output.

### Phase 5: Documentation & System Records
1. Update `README.md`, `docs/PROJECT_STATUS.md`, and `docs/MANUAL.md`.
2. Generate comprehensive post-migration walkthrough document.

---

## 5. Exit Criteria
- [ ] Windows Defender Firewall has an active Inbound Allow rule for TCP port 8000.
- [ ] Router forwards incoming traffic on WAN port to `192.168.1.16:8000`.
- [ ] The `Cloudflared` Windows Service is stopped and removed from `Get-Service`.
- [ ] External HTTP/HTTPS request to the static IP (or `media.anisparvez.in`) reaches the Rust server:
  ```json
  {"engine": "rust", "status": "healthy"}
  ```
- [ ] `scripts/service_status.ps1` runs without errors, showing `MediaServerRust` and `MediaServerPG` running healthy without missing-service warnings for Cloudflared.
- [ ] Existing media streaming, direct play, and transcode workflows remain functional over LAN and WAN.

---

## 6. Risks & Mitigation

| Risk | Impact | Mitigation Strategy |
| :--- | :--- | :--- |
| **ISP blocks port 80/443/8000** | External clients cannot connect | Test port reachability with a public port checker tool. If port 8000 is filtered by ISP, configure router to forward an alternative high port (e.g. 8443, 8080, 28000). |
| **Router changes internal server IP** | Port forwarding points to wrong machine | Configure DHCP Static Lease / Address Reservation on router for `192.168.1.16`. |
| **SSL/HTTPS warning if proxy is disabled** | Browsers show HTTP not secure | If DNS-only (Grey Cloud) is chosen, recommend port mapping 443 with Caddy/Rustls or keep Cloudflare Proxy (Orange Cloud) for free edge SSL. |
| **Cloudflare tunnel orphaned files** | Disk clutter | Gracefully delete service via `sc.exe delete` and clean up configuration files. |

---

## 7. Open Decisions for User

1. **Port Choice for External Ingress:**
   - **Port 8000 direct:** (e.g. `http://media.anisparvez.in:8000` or `http://106.222.224.208:8000`)
   - **Port 443 standard:** If your router supports port translation (External Port 443 $\rightarrow$ Internal Port 8000), URLs can omit the port number.
2. **Cloudflare Proxy vs DNS-Only:**
   - Do you want Cloudflare Proxy (Orange Cloud) kept on the DNS A-record to provide automatic HTTPS SSL encryption and hide your static IP, or completely DNS-only (Grey Cloud)?
