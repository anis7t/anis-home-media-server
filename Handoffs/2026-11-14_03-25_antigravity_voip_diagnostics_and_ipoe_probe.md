# Session Handoff: Router Diagnostics, IPoE Probe, VoIP IPv6 Architecture & Voice Restoration

**Date:** 2026-11-14 03:25 IST  
**Agent:** Antigravity  
**Branch:** `codex/container-phase-0`  
**Status:** Completed, Documented & Verified  

---

## 1. Summary of Objectives & Completed Work

During this session, we resolved gateway administration tooling post-relocation to Bihar, probed Airtel's WAN provisioning protocols (IPoE vs PPPoE), diagnosed softphone (Zoiper) reachability against Airtel's IPv6 IMS network, and restored internal voice service to the Zyxel gateway.

### A. Gateway Tooling & Port Detection Fixes
- **`router-info` Authentication Recovery:** Updated `%LOCALAPPDATA%\router-info\config.json` with active password from `D:\Airtel xstream fiber\secrets.md`. Added automated credential fallback in `scripts/get-router-info.ps1`.
- **Dual-Stack Listener Detection Fix:** Patched `Test-PortListening` in `scripts/get-router-wan.ps1`. Caddy binds to `[::]:443` and `[::]:80` on Windows, causing `Get-NetTCPConnection` CIM objects to return null or non-standard state strings. Added null-safe checking and fallback active TCP socket connection probing.

### B. IPoE vs PPPoE WAN Probe
- **Objective:** Evaluate whether Airtel Bihar supports IPoE (DHCP on VLAN 100) alongside or in place of PPPoE.
- **Probe Outcome:** Executed non-destructive DHCP Discover on VLAN 100. Airtel Bihar BNG (`AIRBRAS_PATNA-1`) completely ignores DHCP requests on VLAN 100; static IP allocation and line authentication strictly mandate PPPoE (`ppp111`).
- **Artifacts:** Documented in [PLAN_TEST_IPOE_ALONGSIDE_PPPOE.md](file:///e:/MediaServer/docs/PLAN_TEST_IPOE_ALONGSIDE_PPPOE.md) and [WALKTHROUGH_IPOE_TEST_PROBE.md](file:///e:/MediaServer/docs/WALKTHROUGH_IPOE_TEST_PROBE.md).

### C. VoIP Network Diagnostics & Zoiper Softphone Analysis
- **Guwahati vs. Bihar Architecture Differences:**
  - *Guwahati (`as.ims.airtel.in`):* Utilized IPv4 (`10.2.9.83`) on `nas0_660`. Standard IPv4 NAT seamlessly masqueraded LAN PC traffic to the voice WAN IP (`100.69.8.232`), enabling Zoiper and `sipcall.py` to function over LAN.
  - *Bihar (`bh.ims.airtel.in`):* Modernized to pure IPv6 (`2401:4900:4c:c465::3`). Airtel Bihar assigns a single static `/117` WAN IP (`2401:4900:120:80::4c:d7ed`).
- **Dynamic LAN IPv6 Prefix Delegation:** Restored dynamic SLAAC/RADVD delegation (`AdvSendAdvert=1`, prefix `2401:4900:1c36:...`) to replace stale hardcoded Guwahati prefixes, restoring global IPv6 reachability across LAN clients.
- **Root Cause of Zoiper Error 408:** Airtel's voice SBC enforces strict BCP 38 anti-spoofing on VLAN 660, silently dropping any packet whose source IP does not match the WAN interface address `2401:4900:120:80::4c:d7ed`. Stock Zyxel firmware lacks NAT66 (IPv6 source NAT), preventing LAN softphones from reaching Airtel IMS without an intermediate NAT66 router or PBX.
- **SIP ALG Deactivation:** Disabled SIP ALG (`SIPALGEnable = 0`) in router NVRAM to prevent kernel packet inspection from mangling UDP 5060 datagrams.
- **Artifacts:** Documented in [WALKTHROUGH_IPV6_LAN_AND_IMS_FORWARDING.md](file:///e:/MediaServer/docs/WALKTHROUGH_IPV6_LAN_AND_IMS_FORWARDING.md) and [WALKTHROUGH_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md](file:///e:/MediaServer/docs/WALKTHROUGH_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md).

### D. Physical RJ-11 Voice Line 1 Restoration
- **Re-enabled Gateway FXS Line 1:** Restored `<Enable>Enabled</Enable>` on `VoiceService.1.VoiceProfile.1.Line.1` in router NVRAM.
- **Live Status Verified:** `statusview.cgi` confirms Account 1 (`+916456459161@bh.ims.airtel.in`) is authenticated and `Up`. Physical analog telephones connected to Phone 1 port are fully operational.
- **Artifacts:** Documented in [PLAN_RESTORE_INTERNAL_VOIP_LINE.md](file:///e:/MediaServer/docs/PLAN_RESTORE_INTERNAL_VOIP_LINE.md) and [WALKTHROUGH_RESTORE_INTERNAL_VOIP_LINE.md](file:///e:/MediaServer/docs/WALKTHROUGH_RESTORE_INTERNAL_VOIP_LINE.md).

---

## 2. Infrastructure & Network State

| Component | Status | Details |
|---|---|---|
| **Egress Static IP** | `223.235.84.216` | Assigned by Airtel Bihar BNG via PPPoE |
| **Cloudflare DNS** | `223.235.84.216` | `media.anisparvez.in` synchronized (DNS-only) |
| **Host IP** | `192.168.1.16` | Static DHCP lease on Zyxel gateway (MAC `08:97:98:74:35:E5`) |
| **Port Forwards** | `Active` | 443 (HTTPS), 80 (HTTP), 8000 (Rust Backend) |
| **Inbound Reachability** | `REACHABLE` | Verified external fetch over 80 and 443 |
| **Host Services** | `Active` | `MediaServerRust` (:8000), `MediaServerCaddy` (:80/:443), `MediaServerPG` (:5432) |
| **Router Voice Line 1** | `Up` | Registered to `bh.ims.airtel.in` |
| **SIP ALG** | `Disabled` | Prevents SIP packet tampering |
| **LAN IPv6** | `Active` | Dynamic SLAAC prefix delegation enabled |

---

## 3. Files Modified & Added in Repository

### Documentation Created
- `docs/PLAN_CONTAINER_PHASE_0_VERIFICATION.md`: Container Phase 0 hardening plan.
- `docs/PLAN_TEST_IPOE_ALONGSIDE_PPPOE.md`: Non-destructive IPoE probe plan.
- `docs/WALKTHROUGH_IPOE_TEST_PROBE.md`: IPoE probe results and evidence.
- `docs/WALKTHROUGH_IPV6_LAN_AND_IMS_FORWARDING.md`: IPv6 prefix delegation and Zoiper diagnosis.
- `docs/PLAN_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md`: SIP ALG deactivation plan.
- `docs/WALKTHROUGH_DISABLE_SIP_ALG_AND_INTERNAL_VOIP.md`: SIP ALG verification.
- `docs/PLAN_RESTORE_INTERNAL_VOIP_LINE.md`: Gateway voice restoration plan.
- `docs/WALKTHROUGH_RESTORE_INTERNAL_VOIP_LINE.md`: Landline registration verification.
- `Handoffs/2026-11-14_03-25_antigravity_voip_diagnostics_and_ipoe_probe.md`: This session handoff.

### Scripts Hardened
- `scripts/phase0/phase0-regression.ps1`: Hardened process cleanup error handling and temp folder resolution.

