# Implementation Plan: Caddy Reverse Proxy & Let's Encrypt HTTPS

## 1. Scope

### What Changes
1. **Caddy Binary Installation:**
   - Deploy standalone `caddy.exe` binary to `E:\MediaServer\bin\caddy.exe` (co-located with NSSM).
2. **Router Port Forwarding (Zyxel AOT5222ZY):**
   - Add automated port forwarding rules via router CGI:
     - External Port `443` (TCP) $\rightarrow$ Internal Port `443` on `192.168.1.16` (HTTPS).
     - External Port `80` (TCP) $\rightarrow$ Internal Port `80` on `192.168.1.16` (HTTP redirect & ACME).
   - Persist rules to router NVRAM.
3. **Windows Firewall Configuration:**
   - Add inbound Windows Firewall rule allowing TCP ports `80` and `443`.
4. **Caddyfile Configuration:**
   - Create `E:\MediaServer\Caddyfile`:
     ```caddyfile
     media.anisparvez.in {
         reverse_proxy 127.0.0.1:8000
     }
     ```
   - Automated Let's Encrypt SSL certificate provisioning and auto-renewal.
   - Automatic HTTP $\rightarrow$ HTTPS redirection.
5. **Persistent Windows Service:**
   - Register Caddy as Windows Service `MediaServerCaddy` using NSSM (`E:\MediaServer\bin\nssm.exe`).
   - Configure automatic start and crash auto-restart.
6. **End-to-End Verification:**
   - Validate external HTTPS certificate validity and handshake.
   - Validate external HTTP $\rightarrow$ HTTPS 308 redirect.
   - Validate React 19 SPA loading and 4K fMP4 streaming (*Ghost in the Cell*) over `https://media.anisparvez.in`.

### What Deliberately Does NOT Change
- **Rust Backend:** Axum production server (`MediaServerRust`) continues running natively on `127.0.0.1:8000`. No code changes to Axum.
- **Database:** PostgreSQL 18.4 (`MediaServerPG`) remains on port 5432.
- **Media & Transcode Pipeline:** Video storage (`D:\Flicks`), dual-GPU transcode engine, and caches remain 100% untouched.
- **Cloudflare DNS:** Cloudflare continues serving authoritative DNS-only (Grey Cloud) for `media.anisparvez.in` $\rightarrow$ `122.163.124.18`.

---

## 2. Exit Criteria

- [ ] `MediaServerCaddy` is registered and running as an automatic Windows Service.
- [ ] Ports `80` and `443` are forwarded to `192.168.1.16` and verified in router NVRAM.
- [ ] Inbound TCP `80` and `443` are allowed in Windows Firewall.
- [ ] External request to `https://media.anisparvez.in/health` returns `HTTP 200` with a valid, globally trusted Let's Encrypt TLS certificate.
- [ ] External request to `http://media.anisparvez.in` redirects automatically to `https://media.anisparvez.in`.
- [ ] External browser loads `https://media.anisparvez.in` with clean URL (no `:8000` port suffix required) and plays *Ghost in the Cell* 4K HLS stream seamlessly.

---

## 3. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| **ISP blocks inbound Port 80** | Let's Encrypt HTTP-01 challenge might fail if Airtel filters inbound port 80. | We have the Cloudflare API token in `cert.pem`. If HTTP-01 fails, Caddy can be configured to use DNS-01 challenge (modifying TXT records via Cloudflare API), which requires zero open inbound ports to issue the certificate. |
| **Port 443 collision** | Caddy fails to bind to port 443. | Verified: `Get-NetTCPConnection` confirmed neither port 80 nor port 443 is in use on the Windows host. |
| **Streaming latency or buffering** | Reverse proxy might introduce packet delay. | Caddy uses Go's zero-copy TCP reverse proxy with native HTTP/2 and HTTP/3 support; localhost overhead is `< 0.5ms`. |

---

## 4. Open Decisions

1. **Service Runner:** Use NSSM (`E:\MediaServer\bin\nssm.exe`) to manage Caddy as `MediaServerCaddy`. This matches the repository's existing standard for `MediaServerRust` and ensures uniform recovery behavior across Windows reboots.

---

## 5. Verification Plan

1. **Local Service Check:**
   - `Get-Service MediaServerCaddy` confirms `Status = Running` and `StartType = Automatic`.
2. **Router Port Forward Check:**
   - Query `port_forwarding_list.cgi` to confirm active entries for ports `80` and `443`.
3. **Public Ingress & Certificate Inspection:**
   - Execute external probe from Google Cloud runner:
     - `curl -Iv https://media.anisparvez.in/health` $\rightarrow$ verify TLS 1.3 handshake, issuer `Let's Encrypt Authority`, and HTTP 200.
     - `curl -Iv http://media.anisparvez.in` $\rightarrow$ verify 308 redirect to `https://media.anisparvez.in`.
4. **4K Playback Test:**
   - Fetch fMP4 playlist and video chunks over `https://media.anisparvez.in/hls/...` to verify end-to-end streaming over HTTPS.
