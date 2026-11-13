# Implementation Plan: Re-enable Internal Voice Line 1 on Zyxel Gateway

**Document Path:** `docs/PLAN_RESTORE_INTERNAL_VOIP_LINE.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Pending User Approval  

---

## 1. Executive Summary & Objective

Now that the investigation into softphone (Zoiper) reachability under Airtel Bihar's IPv6-only IMS infrastructure is complete, the user requested to re-enable the router's internal VoIP Line 1. This restores incoming and outgoing calling capability to the physical **Phone 1 (RJ-11)** port on the back of the Zyxel AOT-5222ZY gateway.

---

## 2. Scope of Work

### In Scope
1. **XML Configuration Update (`patch_restore_voip_line.py`):**
   - In `VoiceService.1.VoiceProfile.1.Line.1`:
     - Change `<Enable PARAMETER="configured" TYPE="string" LENGTH="32">Disabled</Enable>` back to `<Enable PARAMETER="configured" TYPE="string" LENGTH="32">Enabled</Enable>`.
   - Preserve all other active optimizations:
     - Keep SIP ALG disabled (`<SIPALGEnable>0</SIPALGEnable>`).
     - Keep LAN IPv6 prefix delegation / RADVD active.
     - Keep all 3 production NAT port forwards (443, 80, 8000).
2. **Packaging & Flash:**
   - Encrypt to `D:\Airtel xstream fiber\zyxel_work\patched_voip_restored.cfg` using AES-256-CBC.
   - Upload via `zyxel_backup_restore.py` and monitor gateway reboot (~60–90s).
3. **Verification:**
   - Confirm in `statusview.cgi` that Line 1 account status transitions from `Disabled` back to `Up`.
   - Verify all 3 production port forwards, public egress, and Caddy reverse proxy remain 100% operational.

### Deliberately Out of Scope
- No changes to PPPoE internet credentials or static public IP allocation.
- No changes to port forwarding destinations (`192.168.1.16:443`, `80`, `8000`).

---

## 3. Exit Criteria

- [ ] Gateway boots cleanly and web interface returns online.
- [ ] In `statusview.cgi`, `Account Status` for Account 1 (`+916456459161@bh.ims.airtel.in`) is `Up`.
- [ ] Physical RJ-11 Phone port provides dial tone and places/receives calls.
- [ ] Production services (`MediaServerRust`, `MediaServerCaddy`, `MediaServerPG`) and public HTTPS reachability remain 100% operational.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Registration delay with IMS | Phone line takes 30-60s post-boot to register | Normal IMS behavior. We poll `statusview.cgi` post-reboot to verify registration state. |
| Ingress / Port Forwarding disruption | Remote access offline | Port forwarding rules and PPPoE are strictly preserved. `update_cloudflare_dns.ps1` runs post-reboot. |

---

## 5. Open Decisions

- None.

