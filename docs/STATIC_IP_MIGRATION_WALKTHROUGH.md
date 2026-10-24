# Walkthrough: Migration from Cloudflare Tunnel to Direct Static IP Ingress

**Document Path:** `docs/STATIC_IP_MIGRATION_WALKTHROUGH.md`  
**Date:** 2026-10-19  
**Status:** Completed & Verified  

---

## 1. Overview & Objectives

The media server infrastructure previously relied on an outbound Cloudflare Named Tunnel (`cloudflared` Windows Service) to expose `https://media.anisparvez.in`. Following the allocation of a dedicated static public IPv4 address (`106.222.224.208`) from Airtel Xstream Fiber, the goal was to transition the server to direct static IP ingress and decommission Cloudflare Tunnel dependencies.

### Summary of Completed Deliverables
1. **Automated Router Port Forwarding Applied & Persisted:** Programmatically authenticated with the Airtel Zyxel AOT5222ZY gateway (`192.168.1.1`) and configured an active Port Forwarding rule mapping WAN port `8000` to internal server `192.168.1.16:8000` (TCP). Persisted directly to NVRAM (`<X_5067F0_PortMapping>`).
2. **DHCP Address Reservation Verified:** Confirmed the server's Ethernet MAC address (`08:97:98:74:35:E5`) is permanently bound to `192.168.1.16` in the router's `<DHCPStaticAddress>` table.
3. **Windows Defender Firewall Verified:** Confirmed an active inbound allow rule exists for TCP port `8000` (`Rule Name: Media Server WSGI (Waitress Port 8000)`).
4. **Service Decommissioning Automation Created:** Authored `scripts/remove_cloudflared_service.bat` and `scripts/remove_cloudflared_service.ps1` with automatic UAC elevation to cleanly stop and delete the `Cloudflared` Windows Service.
5. **System Diagnostics Updated:** Updated `scripts/service_status.ps1` to track `MediaServerRust` and `MediaServerPG`, verify LAN/WAN ingress, and retire tunnel dependencies.
6. **Documentation Aligned:** Updated `README.md` and repository references to reflect the direct static IP topology.

---

## 2. Router Configuration Details (Airtel Zyxel AOT5222ZY)

Leveraging the tools and configuration structures in `D:\Airtel xstream fiber`, we identified the internal CGI management interface:
- **Admin Gateway:** `http://192.168.1.1/cgi-bin/login_advance.cgi`
- **Session Authentication:** MD5-salted challenge (`MD5(encodeURIComponent(password):sid)`).
- **NAT / Virtual Server CGI:** `http://192.168.1.1/cgi-bin/portForwarding.cgi`

### Applied Port Forwarding Rule
The rule was submitted and verified directly in the router's active table:
```html
<tr align="center">
  <td height="25" class="table_font">1</td>
  <td class="table_font"><img src="/html/images/i_active_on.gif" width="18" height="18" /></td>
  <td class="table_font">MediaServer</td>
  <td class="table_font">8000</td>
  <td class="table_font">8000</td>
  <td class="table_font">8000</td>
  <td class="table_font">8000</td>
  <td class="table_font">192.168.1.16</td>
</tr>
```

### Decrypted Backup & NVRAM Verification
A full encrypted backup (`romfile.cfg`) was generated, downloaded, and decrypted using `zyxel_backup_restore.py`, verifying the exact XML structure stored in NVRAM:
```xml
<X_5067F0_PortMapping>
  <i1>
    <PortMappingDescription PARAMETER="configured" TYPE="string" LENGTH="256">MediaServer</PortMappingDescription>
    <InternalClient PARAMETER="configured" TYPE="string" LENGTH="16">192.168.1.16</InternalClient>
    <PortMappingProtocol PARAMETER="configured" TYPE="string" LENGTH="8">TCP</PortMappingProtocol>
    <PortMappingEnabled PARAMETER="configured" TYPE="boolean">1</PortMappingEnabled>
    <InternalPortEndRange PARAMETER="configured" TYPE="uint16" MAX="65535" MIN="0">8000</InternalPortEndRange>
    <ExternalPortEndRange PARAMETER="configured" TYPE="uint16" MAX="65535" MIN="0">8000</ExternalPortEndRange>
    <InternalPort PARAMETER="configured" TYPE="uint16" MAX="65535" MIN="0">8000</InternalPort>
    <ExternalPort PARAMETER="configured" TYPE="uint16" MAX="65535" MIN="0">8000</ExternalPort>
  </i1>
</X_5067F0_PortMapping>
```

### Static DHCP Reservation
Verified existing static DHCP binding:
```xml
<DHCPStaticAddress>
  <i1>
    <Yiaddr PARAMETER="configured" TYPE="string" LENGTH="16">192.168.1.16</Yiaddr>
    <Chaddr PARAMETER="configured" TYPE="mac">08:97:98:74:35:e5</Chaddr>
    <Enable PARAMETER="configured" TYPE="boolean">1</Enable>
  </i1>
</DHCPStaticAddress>
```

---

## 3. Host System & Diagnostic Verification

### 1. Windows Firewall Status
Queried active rules via `netsh advfirewall firewall show rule`:
```
Rule Name:                            Media Server WSGI (Waitress Port 8000)
----------------------------------------------------------------------
Enabled:                              Yes
Direction:                            In
Protocol:                             TCP
LocalPort:                            8000
Action:                               Allow
```

### 2. Comprehensive Service & Endpoint Probes
Executed `powershell -ExecutionPolicy Bypass -File scripts\service_status.ps1`:
```
====================================================
         Media Server & Ingress Health Check        
====================================================

[1/5] Windows Services Status:
Name            DisplayName                   Status StartType
----            -----------                   ------ ---------
MediaServerPG   MediaServerPG                Running Automatic
MediaServerRust Media Server API (Rust/Axum) Running Automatic

  Cloudflared service status: Running (Decommissioning pending)

[2/5] Port Listeners Check:
  Rust/Axum (Port 8000): Listening by media-server-api (PID: 7620, RAM: 17.8 MB)
  Postgres  (Port 5432): Listening by postgres (PID: 7888)
  Port 8001 (Retired): Correctly closed/released.

[3/5] HTTP Connectivity Tests:
  Local Loopback (http://127.0.0.1:8000/health): OK [Engine: rust, Status: healthy]
  LAN Ingress    (http://192.168.1.16:8000/health): OK [Engine: rust, Status: healthy]
  Local SPA      (http://127.0.0.1:8000/): 200 OK
  Local API      (http://127.0.0.1:8000/api/movies): 200 OK
  Domain Ingress (https://media.anisparvez.in/health): OK [Engine: rust]

[4/5] Active Transcodes & Queue:
  Active Hardware Transcodes: 32
```

---

## 4. Completed Actions & Live Verification

### 1. Cloudflared Windows Service Decommissioned
The elevated restarter script [`scripts\remove_cloudflared_service.bat`](file:///e:/MediaServer/scripts/remove_cloudflared_service.bat) was executed.
- Windows Service `Cloudflared` was stopped and deleted from the Windows Service Control Manager.
- Verified: `Get-Service -Name "Cloudflared"` returns `null` (service no longer exists).

### 2. DNS A-Record Automated via Cloudflare API
Using the authenticated credentials in `C:\Users\anis7\.cloudflared\cert.pem`, the Cloudflare API v4 (`PUT /zones/:zone_id/dns_records/:id`) was invoked directly:
- **Record ID:** `18ff259c41d57052ea0a0cd7ea561ae2`
- **Name:** `media.anisparvez.in`
- **Type:** `A` (converted from CNAME)
- **Content:** `106.222.224.208`
- **Proxy Status:** `false` (DNS-only / Grey Cloud)
- **TTL:** `1` (Auto)

### 3. Public DNS Resolution Verified
Tested via Cloudflare's primary resolver `1.1.1.1`:
```powershell
PS> Resolve-DnsName -Name media.anisparvez.in -Server 1.1.1.1

Name                Type  TTL  Section  IPAddress
----                ----  ---  -------  ---------
media.anisparvez.in A     300  Answer   106.222.224.208
```
`media.anisparvez.in` now points directly to your dedicated static IP `106.222.224.208`.
External clients reach the server directly at:
```
http://media.anisparvez.in:8000
```
