# Walkthrough: Caddy Reverse Proxy & Let's Encrypt HTTPS Setup

## 1. Overview & Architecture

We have successfully migrated the media server from raw unencrypted port-specified URLs to a **clean, production-grade HTTPS architecture** using Caddy, Let's Encrypt, and your direct static/public IP (`122.163.124.18`).

```text
Browser / Mobile (4G/5G) / Smart TV Client
      │
      │ https://media.anisparvez.in (Clean URL — No port number!)
      ▼
Airtel Fiber Gateway (122.163.124.18)
      │
      │ Port 443 (TCP) Port Forward
      ▼
Home Host (192.168.1.16)
      │
      ├─ MediaServerCaddy (Windows Service via NSSM, E:\MediaServer\bin\caddy_custom.exe)
      │    ├─ Automatic Let's Encrypt SSL via Cloudflare DNS-01 Challenge
      │    ├─ Port 443: Native TLS 1.3 Termination & Reverse Proxy
      │    └─ Port 80: Automatic 308 Redirect to HTTPS
      │
      ▼ [localhost:8000]
MediaServerRust (Native Axum Service, E:\MediaServer\rust\)
      ├─ React 19 SPA (web/dist/)
      ├─ Dual-GPU Chunked fMP4 Transcoding
      └─ PostgreSQL 18.4 (MediaServerPG Service)
```

---

## 2. Deliverables & Key Changes

### A. Caddy Binary with Cloudflare DNS Module
* **Location:** `E:\MediaServer\bin\caddy_custom.exe` (Strictly honoring `E:` workspace storage guidelines; `C:` avoided).
* **Compiled Plugins:** Built with `dns.providers.cloudflare` to enable DNS-01 challenge automation.
* **Why DNS-01?** Bypasses all ISP port 80/firewall blocks by validating domain ownership directly against Cloudflare's DNS API.

### B. Automated Caddyfile
* **Location:** `E:\MediaServer\Caddyfile`
```caddyfile
{
    email anis7t@gmail.com
    admin off
}

media.anisparvez.in {
    tls {
        dns cloudflare <API_TOKEN>
    }
    reverse_proxy 127.0.0.1:8000
}
```

### C. Persistent Windows Service
* **Service Name:** `MediaServerCaddy`
* **Managed By:** NSSM (`E:\MediaServer\bin\nssm.exe`)
* **Startup Type:** Automatic (starts on boot without user login, with automatic crash recovery).
* **Logs:** `E:\MediaServer\logs\caddy.log` & `E:\MediaServer\logs\caddy_error.log` (with 10MB log rotation).

### D. Router Port Forwarding (Zyxel AOT5222ZY)
* Port `443` (TCP) $\rightarrow$ `192.168.1.16:443` (HTTPS)
* Port `80` (TCP) $\rightarrow$ `192.168.1.16:80` (HTTP Redirect)
* Port `8000` (TCP) $\rightarrow$ `192.168.1.16:8000` (Direct Ingress)

### E. Inbound Windows Firewall Rules
* Allowed TCP `443` (`Media Server HTTPS (Port 443)`)
* Allowed TCP `80` (`Media Server HTTP (Port 80)`)

---

## 3. Verification & Test Outcomes

### A. Certificate Issuance & TLS Handshake
* **Domain:** `media.anisparvez.in`
* **Issuer:** Let's Encrypt Authority (`YE2`)
* **Protocol:** **TLSv1.3**
* **Cipher:** `TLS_AES_128_GCM_SHA256` (128-bit)
* **Validity:** 90 days (Auto-renewed by Caddy every 60 days indefinitely).

### B. Public Internet Ingress & HTTP Redirect Tests
Tested from external Google Cloud runner (outside your home LAN):

| Request | Response | Status |
| :--- | :--- | :--- |
| `GET http://media.anisparvez.in/health` | `HTTP/1.1 308 Permanent Redirect` $\rightarrow$ `https://media.anisparvez.in/health` | **PASS** |
| `GET https://media.anisparvez.in/health` | `HTTP/1.1 200 OK` (`{"engine":"rust","status":"healthy"}`) | **PASS** |
| `GET https://media.anisparvez.in/player/Ghost.in.the.Cell...` | `HTTP/1.1 200 OK` (React 19 SPA HTML) | **PASS** |
| `GET https://media.anisparvez.in/hls/Ghost.in.the.Cell.../playlist.m3u8` | `HTTP/1.1 200 OK` (Adaptive 4K/1440p fMP4 Master Playlist) | **PASS** |

### C. Unified Service Status (`scripts/service_status.ps1`)
All three persistent services are running in harmony:
```text
Name             DisplayName                   Status  StartType
----             -----------                   ------  ---------
MediaServerCaddy MediaServerCaddy              Running Automatic
MediaServerPG    MediaServerPG                 Running Automatic
MediaServerRust  Media Server API (Rust/Axum)  Running Automatic

Port Listeners:
  Rust/Axum (Port 8000) : Listening (PID: 21264, RAM: 22.3 MB)
  Postgres  (Port 5432) : Listening (PID: 7888)
  Caddy     (Port 443)  : Listening (PID: 16720)
  Caddy     (Port 80)   : Listening (HTTP -> HTTPS redirect)

Connectivity:
  Domain HTTPS (https://media.anisparvez.in/health): OK [TLS Valid, Engine: rust]
```

---

## 4. User Access URLs

You and your users can now access your media server anywhere in the world using standard, clean HTTPS:

* **Home Library:** [https://media.anisparvez.in](https://media.anisparvez.in)
* **Direct Player (*Ghost in the Cell* 4K):** [https://media.anisparvez.in/player/Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT.mkv](https://media.anisparvez.in/player/Ghost.in.the.Cell.2026.2160p.NF.WEB-DL.DDP5.1.H.265-PandaQT.mkv)
