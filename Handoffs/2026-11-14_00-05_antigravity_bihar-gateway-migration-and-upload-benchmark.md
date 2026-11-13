# Session Handoff: Airtel Bihar Relocation, Static IP Ingress & Upload Benchmark

**Date:** 2026-11-14 00:05 IST  
**Agent:** Antigravity  
**Branch:** `main` (tracking `origin/main` at `fc81b06`)  
**Status:** Completed, Verified & Shipped  

---

## 1. Objectives & Context

The server host moved from Guwahati to Bihar under the same Airtel Xstream Fiber subscription.
Key starting conditions:
- **Router Hardware:** Zyxel AOT-5222ZY ONT (`192.168.1.1`) running firmware `AOT5222ZY_R_1.3`.
- **Router State:** Factory reset; port forwarding and DHCP reservation tables were completely empty. Credentials: `admin` / `gUWAHATI@6E` (from `D:\Airtel xstream fiber\secret.md`).
- **New ISP Static IP:** Re-allocated by Airtel in Bihar to `223.235.84.179`.
- **DNS / Domain:** `media.anisparvez.in` still pointed to previous IP (`171.50.176.119`) in Cloudflare.
- **Laptop Host:** Windows 11 host with Realtek Gaming GbE Family Controller (`Ethernet`, MAC `08:97:98:74:35:E5`), receiving dynamic IP `192.168.1.18`.

---

## 2. Completed Deliverables

### A. Router Reconfiguration
1. **Static DHCP Reservation:**
   - Authored `scripts/router_dhcp_lease.ps1`.
   - Bound MAC `08:97:98:74:35:E5` to static IP `192.168.1.16` on `/cgi-bin/staticDHCP.cgi` with global static DHCP enabled.
2. **NAT Port Forwarding Rules:**
   - Hardened `scripts/router_port_forward.ps1` to handle single-element arrays robustly (`@($before).Count`).
   - Reconfigured and verified three active rules pointing to `192.168.1.16`:
     - `HTTPS`: External `443` -> Internal `443` (TCP)
     - `HTTP`: External `80` -> Internal `80` (TCP)
     - `MediaServer`: External `8000` -> Internal `8000` (TCP)
3. **Decrypted Backup Captured:**
   - Executed `D:\Airtel xstream fiber\zyxel_backup_restore.py` to pull and decrypt live router NVRAM to `D:\Airtel xstream fiber\live_now.xml` (9,351 lines) and `backup_with_portforward.xml`.

### B. Host Network Configuration (Windows 11)
- Static IP configured on adapter `Ethernet`:
  - IP: `192.168.1.16`
  - Subnet Mask: `255.255.255.0` (/24)
  - Gateway: `192.168.1.1`
  - DNS: `192.168.1.1`, `1.1.1.1`
- Verified gateway ping (`<1ms`) and internet reachability.

### C. Cloudflare DNS Dynamic Update
- Authored `scripts/update_cloudflare_dns.ps1` (auto-detects public egress IP via `ipify.org` if not specified, reads scoped API token from `Caddyfile`).
- Updated `media.anisparvez.in` DNS A-record to `223.235.84.179` with `proxied: false` (DNS-only direct ingress).
- Verified DNS propagation via `1.1.1.1`.

### D. ISP Speedtest & Upload Benchmark
- **Ookla Speedtest CLI:**
  - Download: **201.05 Mbps**
  - Upload: **153.17 Mbps**
  - Latency: 63.98ms, Packet Loss: 0.0%
- **Direct Upload Handshake & Throughput Benchmark:**
  - Verified resumable upload chunk API (`POST /api/upload/chunk/init` -> `POST /api/upload/chunk/{id}` -> `GET /api/upload/chunk/{id}` -> `DELETE /api/upload/chunk/{id}`).
  - Tested production 8 MiB chunks over `https://media.anisparvez.in`: sustained **157.59 Mbps** (0.426s for 8 MiB), proving 100% saturation of the physical ISP uplink with zero Cloudflare proxy throttling.

### E. Git Branches & Repository State
- Checkpointed working-tree container pilot changes on `codex/container-phase-0` (`236f45a`).
- Switched to production `main` and fast-forwarded to `origin/main` (`fc81b06`).
- Added `.docker/` to `.gitignore`.
- Updated `docs/PROJECT_STATUS.md`.

---

## 3. Verification Commands & Health Status

```powershell
# Ingress Health
powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1

# DNS Verification
Resolve-DnsName -Name media.anisparvez.in -Server 1.1.1.1

# External Ingress Probes
curl.exe -I https://media.anisparvez.in/
curl.exe -s -i "http://223.235.84.179:8000/health"
```

All services (`MediaServerRust`, `MediaServerCaddy`, `MediaServerPG`) are active and verified healthy.
