# Walkthrough: Internal Voice Line 1 Restoration on Zyxel Gateway

**Document Path:** `docs/WALKTHROUGH_RESTORE_INTERNAL_VOIP_LINE.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Completed & Live  

---

## 1. Overview & Objectives

Following the softphone (Zoiper) tests under Airtel Bihar's IPv6 infrastructure, the user requested to re-enable the gateway's internal telephone line. We executed the approved plan ([PLAN_RESTORE_INTERNAL_VOIP_LINE.md](file:///e:/MediaServer/docs/PLAN_RESTORE_INTERNAL_VOIP_LINE.md)):
1. **Re-enabled Voice Line 1:** Restored `<Enable>Enabled</Enable>` on `VoiceService.1.VoiceProfile.1.Line.1`.
2. **Preserved Network Optimizations:** Kept SIP ALG disabled (`<SIPALGEnable>0</SIPALGEnable>`) and dynamic IPv6 SLAAC/RADVD delegation active on the LAN.
3. **Verified Landline Registration:** Confirmed in `statusview.cgi` that Account 1 (`+916456459161@bh.ims.airtel.in`) is authenticated and `Up`.
4. **Verified Production Stability:** Confirmed that all 3 NAT port forwards (443, 80, 8000), external inbound reachability, and Cloudflare DNS remained 100% operational.

---

## 2. Changes Applied

### A. Configuration Patch (`patched_voip_restored.xml`)
```xml
<DirectoryNumber PARAMETER="configured" TYPE="string" LENGTH="64">+916456459161@bh.ims.airtel.in</DirectoryNumber>
<Enable PARAMETER="configured" TYPE="string" LENGTH="32">Enabled</Enable>
```

### B. Deployment & Boot Verification
- Encrypted with AES-256-CBC to `D:\Airtel xstream fiber\zyxel_work\patched_voip_restored.cfg`.
- Uploaded to the router at `192.168.1.1` and monitored reboot.

---

## 3. Post-Reboot Verification & Live Telemetry

1. **Voice Registration Status (`statusview.cgi`):**
   ```text
   Account:        1
   Account Status: Up
   URI:            +916456459161@bh.ims.airtel.in
   ```
   *The router's internal telephone line is fully re-registered with Airtel IMS. The physical Phone 1 (RJ-11) jack is active.*

2. **Firewall & IPv6 Status:**
   - **SIP ALG:** `disabled`
   - **LAN Global IPv6:** Active (`2401:4900:1c36:...` dynamic prefix delegation).

3. **Production Services & Remote Access:**
   - **Public Static Egress:** `223.235.84.216`.
   - **Cloudflare DNS:** Synchronized to `223.235.84.216`.
   - **Port Forwards:** 443, 80, 8000 mapped to `192.168.1.16`.
   - **Inbound Reachability:**
     ```text
     Inbound :80       : REACHABLE - external fetch returned content
     Inbound :443      : REACHABLE - external fetch returned content
     ```
   - **Local Services:** `MediaServerRust`, `MediaServerCaddy`, `MediaServerPG` all healthy and running.

