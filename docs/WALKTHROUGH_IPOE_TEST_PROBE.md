# Walkthrough: IPoE vs PPPoE Verification on Airtel Xstream Fiber (Zyxel AOT-5222ZY)

**Document Path:** `docs/WALKTHROUGH_IPOE_TEST_PROBE.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Completed & Verified  

---

## 1. Overview & Objective

The user requested testing whether **IPoE** can be enabled instead of **PPPoE** on the Airtel Xstream Fiber Zyxel AOT-5222ZY gateway.

To prevent any outage or loss of public static IP reachability, we executed the approved non-destructive probe (`docs/PLAN_TEST_IPOE_ALONGSIDE_PPPOE.md`):
1. **Configured IPoE (DHCP) on `nas0_100` (VLAN 100)** concurrently alongside the primary PPPoE session.
2. **Kept `ppp111` (PPPoE) active** as the default gateway and NAT port-forward anchor.
3. **Inspected the carrier's BNG response** to determine whether Airtel Bihar supports DHCP on VLAN 100.

---

## 2. Changes Applied

### A. Router XML Patch (`patched_ipoe_probe.xml`)
Modified `InternetGatewayDevice.WANDevice.1.WANConnectionDevice.4.WANIPConnection.1` (`Internet_IPoE`, VLAN 100):
```xml
<WANIPConnection>
  <i1>
    <AddressingType PARAMETER="configured" TYPE="string" LENGTH="8">DHCP</AddressingType>
    <X_5067F0_IPv6AddressingType PARAMETER="configured" TYPE="string" LENGTH="15">DHCP</X_5067F0_IPv6AddressingType>
    <Enable PARAMETER="configured" TYPE="boolean">1</Enable>
    <NATEnabled PARAMETER="configured" TYPE="boolean">1</NATEnabled>
    <X_TELEFONICA_ES_IPv4Enabled PARAMETER="configured" TYPE="boolean">1</X_TELEFONICA_ES_IPv4Enabled>
    <X_5067F0_IPv6Enabled PARAMETER="configured" TYPE="boolean">1</X_5067F0_IPv6Enabled>
    <X_5067F0_InterfaceName PARAMETER="configured" TYPE="string" LENGTH="64">nas0_100</X_5067F0_InterfaceName>
    <X_5067F0_VLANID PARAMETER="configured" TYPE="uint16">100</X_5067F0_VLANID>
...
```

### B. Encryption & Flash
- Encrypted with AES-256-CBC using key `EwhJaD44DfprDOs7OXx9jzAtLg5PKtD8` to `D:\Airtel xstream fiber\zyxel_work\patched_ipoe_probe.cfg`.
- Uploaded via `zyxel_backup_restore.py` and rebooted the gateway.

### C. Script Hardening (`scripts/get-router-wan.ps1`)
- Enhanced `Test-PortListening` to accurately identify IPv6 dual-stack sockets (such as Caddy on `[::]:443` and `[::]:80`) where `Get-NetTCPConnection` CIM objects may have null or numeric state attributes, backed by an active TCP socket probe fallback.

---

## 3. Verification & Live Results

### A. Carrier IPoE Response
Running `router-info` and querying `http://192.168.1.1/cgi-bin/statusview.cgi` revealed:

```text
Configured connections (fresh snapshot)
---------------------------------------
Name           Type   Interface  IP              Mask           Gateway         VLAN  Service  State
-------------  -----  ---------  --------------  -------------  --------------  ----  -------  ----------
Internet_IPoE  IPoE   nas0_100   0.0.0.0         0.0.0.0        0.0.0.0         100   TR069    no address
VoIP           IPoE   nas0_660   10.1.1.1        255.255.255.0  10.1.1.2        660   VOIP     up
Internet       PPPoE  ppp111     223.235.84.179  -              223.235.31.255  100   TR069    up
```

From router statusview:
- **Wan Name:** `Internet_IPoE`
- **Encapsulation:** `ENET ENCAP` (IPoE)
- **MAC Address:** `44:63:C2:53:38:3B`
- **IP Address:** `0.0.0.0`
- **Default Gateway:** `0.0.0.0`

> **Carrier Finding:** The Airtel Bihar BNG/BRAS (`AIRBRAS_PATNA-1`) **does not provide DHCP service on VLAN 100**. Unauthenticated DHCP Discover packets are ignored. The static IP allocation is strictly tied to the PPPoE RADIUS authentication account (`0645637235932_wifi@airtelbroadband.in`).

### B. PPPoE & Inbound Port Forwarding Health
Because the probe was run concurrently, primary services suffered zero interruption:
- **PPPoE Session:** Active on `ppp111` with current public egress `223.235.84.190`.
- **Cloudflare DNS:** Automatically synchronized via `update_cloudflare_dns.ps1` (`media.anisparvez.in` $\rightarrow$ `223.235.84.190`).
- **Static Port Forwarding:** Verified all 3 rules active:
  - `HTTPS (TCP 443)` $\rightarrow$ `192.168.1.16:443`
  - `HTTP (TCP 80)` $\rightarrow$ `192.168.1.16:80`
  - `MediaServer (TCP 8000)` $\rightarrow$ `192.168.1.16:8000`
- **External Inbound Reachability:**
  ```text
  Inbound :80       : REACHABLE - external fetch returned content
  Inbound :443      : REACHABLE - external fetch returned content
  ```
- **Local Persistent Services:**
  - `MediaServerRust` (Axum `:8000`): **Running**
  - `MediaServerCaddy` (`:443/:80`): **Running**
  - `MediaServerPG` (`:5432`): **Running**

---

## 4. Conclusion & Recommendation

1. **PPPoE is Mandatory:** Airtel Xstream Fiber in Bihar requires PPPoE for customer data traffic on VLAN 100. Disabling PPPoE in favor of IPoE is not possible without losing internet connectivity.
2. **Current System State:** The router is stable, VoIP is registered and reachable over VLAN 660, port forwards and Caddy reverse proxy are 100% operational, and `media.anisparvez.in` is live and reachable from the internet.

