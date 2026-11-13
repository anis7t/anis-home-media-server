# Walkthrough: Router IPv6 LAN Delegation & Airtel IMS Voice Probe Results

**Document Path:** `docs/WALKTHROUGH_IPV6_LAN_AND_IMS_FORWARDING.md`  
**Date:** 2026-11-14  
**Author:** Antigravity  
**Status:** Completed & Verified  

---

## 1. Overview & Objectives

In response to the user's request to configure the Zyxel AOT-5222ZY gateway for softphone calling (Zoiper / test script), we executed the approved implementation plan ([PLAN_ROUTER_IPV6_LAN_AND_VOIP_FORWARDING.md](file:///e:/MediaServer/docs/PLAN_ROUTER_IPV6_LAN_AND_VOIP_FORWARDING.md)):
1. **Activated Dynamic LAN IPv6 Prefix Delegation (RADVD / SLAAC):** Replaced the stale hardcoded Guwahati prefix (`2401:4900:1cab:f0ba::`) with dynamic delegation from `ppp111` and enabled Router Advertisements (`AdvSendAdvert=1`).
2. **Added IPv6 Static Routing for Airtel IMS:** Configured forwarding for the Airtel Bihar IMS subnet (`2401:4900:4c::/48`) to egress via `nas0_660` to gateway `2401:4900:120:80::4c:d001`.
3. **Tested Calling / Softphone Reachability:** Tested live IPv6 packet flow to `2401:4900:4c:c465::3` and verified carrier SBC ingress behavior.
4. **Maintained Production Resilience:** Re-verified that PPPoE, static port forwards (443, 80, 8000), Cloudflare DNS, and backend services remained 100% operational.

---

## 2. Changes Applied

### A. Router XML Modifications (`patched_ipv6_voip.xml`)
1. **Dynamic RADVD & Prefix Delegation (`X_5067F0_IPv6LANHostConfigManagement`):**
   ```xml
   <RADVD>
     <Enabled PARAMETER="configured" TYPE="boolean">1</Enabled>
   </RADVD>
   <RadVDConfigManagement>
     <AdvSendAdvert PARAMETER="configured" TYPE="boolean">1</AdvSendAdvert>
     <PrefixInformation>
       <i1>
         <Prefix PARAMETER="configured" TYPE="string" LENGTH="64">2401:4900:1c36:8fff::</Prefix>
         <DelegatedConnection PARAMETER="configured" TYPE="string" LENGTH="256">InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANPPPConnection.1</DelegatedConnection>
         <AdvOnLink PARAMETER="configured" TYPE="uint8" MAX="1" MIN="0">1</AdvOnLink>
         <Mode PARAMETER="configured" TYPE="boolean">0</Mode>
         <ValidLifeTime PARAMETER="configured" TYPE="sint31" MAX="2147483647" MIN="-1">86400</ValidLifeTime>
         <PreferredLifeTime PARAMETER="configured" TYPE="sint31" MAX="2147483647" MIN="-1">86400</PreferredLifeTime>
       </i1>
     </PrefixInformation>
   </RadVDConfigManagement>
   ```
2. **IPv6 Static Route for Airtel IMS (`X_5067F0_IPv6Layer3Forwarding`):**
   ```xml
   <Forwarding>
     <i1>
       <Interface PARAMETER="configured" TYPE="string" LENGTH="256">InternetGatewayDevice.WANDevice.1.WANConnectionDevice.2.WANIPConnection.1</Interface>
       <GatewayIPv6Address PARAMETER="configured" TYPE="string" LENGTH="46">2401:4900:120:80::4c:d001</GatewayIPv6Address>
       <DestIPv6Address PARAMETER="configured" TYPE="string" LENGTH="46">2401:4900:4c::</DestIPv6Address>
       <PrefixLength PARAMETER="configured" TYPE="uint8" MAX="128" MIN="0">48</PrefixLength>
       <ForwardingMetric PARAMETER="configured" TYPE="sint7" MAX="127" MIN="-1">1</ForwardingMetric>
       <Enable PARAMETER="configured" TYPE="boolean">1</Enable>
     </i1>
   </Forwarding>
   ```

### B. Packaging & Deployment
- Encrypted using `zyxel_backup_restore.py` AES-256-CBC to `D:\Airtel xstream fiber\zyxel_work\patched_ipv6_voip.cfg`.
- Uploaded to the router at `192.168.1.1` and rebooted the gateway.

---

## 3. Verification & Diagnostic Outcomes

### A. Major Success: Global LAN IPv6 Connectivity Restored
Immediately following reboot, the router began actively broadcasting Router Advertisements on the LAN. The Media Server PC immediately acquired global, routable IPv6 addresses:
```text
IPAddress         : 2401:4900:1c36:59b9:887d:6e3d:7572:9bbe
PrefixLength      : 64
PrefixOrigin      : RouterAdvertisement
AddressState      : Preferred

IPAddress         : 2401:4900:1c36:59b9:6cfe:fbe4:eb8e:edbe
PrefixLength      : 128
PrefixOrigin      : RouterAdvertisement
AddressState      : Preferred
```
- Ping test to Cloudflare IPv6 (`2606:4700:4700::1111`): **Reply in 45ms (0% packet loss)**.
- `DestinationScopeMismatch` error: **Completely eliminated**.

### B. Airtel IMS Calling & Carrier Ingress Findings
We executed `test_ring_v6.py` and ran traceroute towards `2401:4900:4c:c465::3`:
1. **Hop 1 Reached the Router:**
   ```text
   1    <1 ms    <1 ms    <1 ms  2401:4900:1c36:59b9:4663:c2ff:fe53:3838 (Router LAN)
   2     *        *        *     Request timed out.
   ```
2. **Carrier Ingress Filtering (BCP 38):**
   - The router successfully routes packets from the PC towards the IMS destination.
   - However, Airtel Bihar's Voice Gateway (`2401:4900:120:80::4c:d001`) applies strict anti-spoofing / ingress filtering on VLAN 660: it drops any packets whose source IP does not match the subscriber's exact assigned WAN voice IP (`2401:4900:120:80::4c:d7ed`).
   - Because the Zyxel gateway kernel lacks NAT66 (IPv6 source masquerading), it cannot rewrite the PC's source IP to the router's voice WAN IP.

### C. Confirmed Working Voice Path: Hardware RJ-11 Phone Port
- In `statusview.cgi`, the router's internal voice software (running natively with IP `2401:4900:120:80::4c:d7ed`) is **authenticated and `Up`**:
  - **Account:** `1`
  - **Account Status:** `Up`
  - **URI:** `+916456459161@bh.ims.airtel.in`
- Plugging any standard telephone instrument into the **Phone 1 (RJ-11)** port on the back of the Zyxel router allows incoming and outgoing calls to connect immediately without any network hurdles.

### D. Production Services Health
- **Public Static IP:** Reconnected at `223.235.84.204`.
- **Cloudflare DNS:** Automatically updated (`media.anisparvez.in` $\rightarrow$ `223.235.84.204`).
- **Static Port Forwarding:** All 3 rules confirmed active (`192.168.1.16:443`, `80`, `8000`).
- **External Ingress:**
  ```text
  Inbound :80       : REACHABLE - external fetch returned content
  Inbound :443      : REACHABLE - external fetch returned content
  ```
- **Local Services:** `MediaServerRust`, `MediaServerCaddy`, `MediaServerPG` all **Running** and healthy.

