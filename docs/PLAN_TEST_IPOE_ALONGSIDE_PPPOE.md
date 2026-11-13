# Implementation Plan: Test IPoE (DHCP) on VLAN 100 Safely Alongside PPPoE

**Document Path:** `docs/PLAN_TEST_IPOE_ALONGSIDE_PPPOE.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Pending User Approval  

---

## 1. Executive Summary & Objective

The user requested testing whether **IPoE** can be enabled instead of PPPoE on the Airtel Xstream Fiber Zyxel AOT-5222ZY gateway. 

In Bihar (Kishanganj/Patna circle), Airtel provisioned this static IP line with PPPoE credentials (`0645637235932_wifi@airtelbroadband.in`) on VLAN 100. Disabling PPPoE entirely would risk a total loss of internet connectivity and public ingress if the carrier's BNG/BRAS rejects unauthenticated IPoE DHCP requests.

To eliminate this risk, this plan defines a **non-destructive concurrent probe**:
- **Keep PPPoE Active:** The primary internet default route, public static IP, and all 3 NAT port forwards (80, 443, 8000) remain bound to `ppp111` (PPPoE).
- **Activate Secondary IPoE Probe:** Configure interface `nas0_100` (`Internet_IPoE`, VLAN 100) with DHCP client enabled alongside PPPoE.
- **Inspect Carrier Response:** Check if the ISP BNG/BRAS offers an IP address to the DHCP Discover request without disrupting the active PPPoE session.

---

## 2. Scope of Work

### In Scope
1. **XML Configuration Patch (`patch_test_ipoe.py`):**
   - Target interface: `InternetGatewayDevice.WANDevice.1.WANConnectionDevice.4.WANIPConnection.1` (`Internet_IPoE`, `nas0_100`, VLAN 100).
   - Change `<AddressingType>Static</AddressingType>` to `<AddressingType>DHCP</AddressingType>`.
   - Set `<Enable>1</Enable>`.
   - Set `<NATEnabled>1</NATEnabled>`.
   - Set `<X_TELEFONICA_ES_IPv4Enabled>1</X_TELEFONICA_ES_IPv4Enabled>`.
   - Preserve `DefaultConnectionService` as `InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1` (`ppp111`) so default traffic and port forwards remain on PPPoE.
2. **Package Encryption & Application:**
   - Encrypt the patched XML using AES-256-CBC (`EwhJaD44DfprDOs7OXx9jzAtLg5PKtD8`).
   - Upload via `zyxel_backup_restore.py` and reboot the router (~60–90s).
3. **Post-Reboot Verification & Telemetry:**
   - Query `statusview.cgi` and run `router-info -SkipPortScan`.
   - Inspect the state of `Internet_IPoE` (`nas0_100`):
     - **Case A (Carrier supports IPoE):** `nas0_100` receives an IP address (e.g. public or CGNAT `100.64.x.x`).
     - **Case B (Carrier requires PPPoE):** `nas0_100` receives `0.0.0.0` / no response from BRAS.
   - Verify that PPPoE (`ppp111`), all 3 NAT port forwarding rules, and Media Server remote reachability remain 100% unaffected regardless of the IPoE outcome.

### Deliberately Out of Scope
- No disabling or deleting of `WANPPPConnection.1` (PPPoE stays active as safety anchor).
- No modifications to port forwarding rule destinations or internal LAN bindings (`192.168.1.16`).
- No changes to Cloudflare DNS or local application services.

---

## 3. Exit Criteria

- [ ] Patched XML validly encrypts and successfully restores to the Zyxel gateway.
- [ ] Router finishes reboot and web GUI on `192.168.1.1:80` returns online.
- [ ] All 3 production NAT port forwards (80, 443, 8000) remain active on `ppp111`.
- [ ] PPPoE session establishes cleanly and internet egress continues functioning.
- [ ] The live status of `Internet_IPoE` (`nas0_100`) is checked and documented (whether an IP was acquired via DHCP or ignored by the ISP).

---

## 4. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Disruption to internet / remote access | Ingress down | PPPoE remains the primary active interface and default route. If IPoE DHCP fails, PPPoE carries 100% of traffic. |
| Carrier VLAN 100 single-MAC or single-session restriction | BRAS disconnects PPPoE if concurrent DHCP is seen | If carrier drops PPPoE upon detecting DHCP on VLAN 100, immediate rollback file `D:\Airtel xstream fiber\zyxel_work\patched_voip.cfg` is ready on disk to restore in one step. |
| Configuration reject | Gateway reverts to previous config | Verified encryption tool (`zyxel_backup_restore.py`) and standard TR-098 schema are used. |

---

## 5. Open Decisions

- None. This probe is non-destructive and preserves the existing working PPPoE connection while testing the carrier's IPoE capability.

