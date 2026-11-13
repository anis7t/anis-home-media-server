# Walkthrough: SIP ALG Deactivation & Internal Voice Line Release for Zoiper Exclusivity

**Document Path:** `docs/WALKTHROUGH_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Completed & Live  

---

## 1. Overview & Objectives

Following the resolution of the DNS error (code 923), Zoiper reported `Request Timeout (code: 408)`. To eliminate router-level interception and account binding conflicts, we executed the approved plan ([PLAN_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md](file:///e:/MediaServer/docs/PLAN_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md)):
1. **Disabled Router SIP ALG:** Set `<SIPALGEnable>0</SIPALGEnable>` in `<X_5067F0_NATExt>` to prevent the Linux kernel (`nf_nat_sip`) from intercepting and mangling UDP port 5060 IPv6 packets.
2. **Deactivated Internal Hardware SIP Line:** Set `<Enable>Disabled</Enable>` on `VoiceService.1.VoiceProfile.1.Line.1` so the router releases its registration with Airtel IMS, giving Zoiper uninhibited, exclusive access to `+916456459161@bh.ims.airtel.in`.
3. **Verified Production Stability:** Verified that PPPoE, all 3 NAT port forwards (443, 80, 8000), external inbound reachability, and Cloudflare DNS remained 100% operational.

---

## 2. Changes Applied

### A. Configuration Patch (`patched_zoiper_exclusive.xml`)
1. **SIP ALG Disabled:**
   ```xml
   <X_5067F0_NATExt>
     <SIPALGEnable PARAMETER="configured" TYPE="boolean">0</SIPALGEnable>
     ...
   </X_5067F0_NATExt>
   ```
2. **Internal Voice Line Deactivated:**
   ```xml
   <DirectoryNumber PARAMETER="configured" TYPE="string" LENGTH="64">+916456459161@bh.ims.airtel.in</DirectoryNumber>
   <Enable PARAMETER="configured" TYPE="string" LENGTH="32">Disabled</Enable>
   ```

### B. Deployment & Boot Verification
- Encrypted with AES-256-CBC to `D:\Airtel xstream fiber\zyxel_work\patched_zoiper_exclusive.cfg`.
- Restored to the Zyxel gateway at `192.168.1.1` and monitored reboot.

---

## 3. Post-Reboot Verification & Live Telemetry

1. **Firewall Status (`router-info`):**
   ```text
   ==============================================================================
    FIREWALL / INBOUND
   ==============================================================================
   WAN default       : Drop
   WAN permits       : TCP 7547 (Default_TR069), TCP 8883 (EMBEDUR_TCP)
   SIP ALG           : disabled
   ```
   *SIP ALG is confirmed completely disabled.*
2. **Global IPv6 LAN Status:**
   - PC assigned address: `2401:4900:1c36:6513:5db:3dfb:466a:e905` (Preferred, dynamic SLAAC).
3. **Production Reachability:**
   - **Public Egress:** `223.235.84.211`.
   - **Cloudflare DNS:** Synchronized to `223.235.84.211`.
   - **Static Port Forwards:** All 3 active (`443`, `80`, `8000` $\rightarrow$ `192.168.1.16`).
   - **Inbound Probe:** Ports 80 and 443 confirmed `REACHABLE` from the outside world.
   - **Backend Services:** `MediaServerRust`, `MediaServerCaddy`, `MediaServerPG` all healthy and running.

