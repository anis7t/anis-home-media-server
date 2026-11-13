# Implementation Plan: Disable Router SIP ALG and Deactivate Internal Voice Client for Zoiper Exclusivity

**Document Path:** `docs/PLAN_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Pending User Approval  

---

## 1. Executive Summary & Objective

In Zoiper, the previous error `No DNS results (code: 923)` was eliminated following the global IPv6 LAN activation. However, registration attempts currently return **`Request Timeout (code: 408)`**.

Two router-side mechanisms are causing this timeout:
1. **SIP ALG Kernel Module Active:** `<SIPALGEnable>1</SIPALGEnable>` intercepts all UDP port 5060 traffic passing through the router. SIP ALG frequently mangles or drops IPv6 SIP headers from LAN softphones.
2. **Account Concurrency Conflict:** The Zyxel gateway's built-in voice ATA is actively registered to Airtel IMS with `+916456459161@bh.ims.airtel.in` (`Account Status: Up`). Airtel IMS permits only one active registration binding per subscriber landline number.

The objective of this plan is to:
1. **Disable SIP ALG:** Set `<SIPALGEnable>0</SIPALGEnable>` so the router cleanly passes UDP 5060 packets between Zoiper and Airtel IMS without kernel tampering.
2. **Disable the Router's Internal SIP Line:** Set `<Enable>Disabled</Enable>` on `VoiceService.1.VoiceProfile.1.Line.1` so the router releases the SIP registration binding with Airtel IMS, giving Zoiper exclusive access to the account.
3. **Preserve Production Stability:** Maintain all 3 NAT port forwards (443, 80, 8000), PPPoE internet, and IPv6 LAN routing.

---

## 2. Scope of Work

### In Scope
1. **XML Configuration Patch (`patch_disable_sip_alg.py`):**
   - Source: `check_live.xml` (the currently active live configuration).
   - In `<X_5067F0_NATExt>`: Change `<SIPALGEnable>1</SIPALGEnable>` to `<SIPALGEnable>0</SIPALGEnable>`.
   - In `VoiceService.1.VoiceProfile.1.Line.1`: Change `<Enable PARAMETER="configured" TYPE="string" LENGTH="32">Enabled</Enable>` to `<Enable PARAMETER="configured" TYPE="string" LENGTH="32">Disabled</Enable>`.
2. **Encryption & Gateway Update:**
   - Encrypt the patched XML to `D:\Airtel xstream fiber\zyxel_work\patched_zoiper_exclusive.cfg` using AES-256-CBC.
   - Upload via `zyxel_backup_restore.py` and reboot the gateway (~60–90s).
3. **Verification:**
   - Confirm in `statusview.cgi` that SIP ALG is disabled and Line 1 status is `Down` / `Disabled`.
   - Re-test registration in Zoiper.
   - Verify all 3 production NAT port forwards and external HTTPS reachability.

### Deliberately Out of Scope
- No changes to PPPoE internet credentials, IP allocation, or LAN IPv6 SLAAC configuration.
- No changes to external port mappings (`192.168.1.16:443`, `80`, `8000`).

---

## 3. Exit Criteria

- [ ] Router finishes reboot and web management returns online.
- [ ] `SIPALGEnable` is confirmed set to `0` in active state.
- [ ] Router internal VoIP line status is `Disabled`.
- [ ] Zoiper can re-attempt registration without port 5060 kernel interception.
- [ ] All 3 production NAT port forwards and external ingress remain 100% operational.

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| RJ-11 analog phone on router stops ringing | Physical phone inactive while testing Zoiper | Expected behavior. If the user ever wants to revert back to using the physical RJ-11 phone, `check_live.cfg` or setting `<Enable>Enabled</Enable>` restores it immediately. |
| Ingress / Port Forwarding disruption | Remote access offline | Port forwarding rules and PPPoE are strictly preserved. `update_cloudflare_dns.ps1` runs post-reboot. |

---

## 5. Open Decisions

- None. The user explicitly chose the recommended option to disable both SIP ALG and internal voice for Zoiper exclusivity.

