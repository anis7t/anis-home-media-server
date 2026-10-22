chore(ops): the static IP is provisioned, verified, and live

Airtel reprovisioned the line on 2026-10-22. The router now holds a real
static public IPv4 address, the site is back, and the earlier carrier-NAT
diagnosis is closed. This records what changed, how it was proven, and what
still needs the owner's attention.

## THE CHANGE

On 2026-10-21 the line was behind carrier NAT: the router's WAN was a
rotating 100.x address (`122.163.124.18 -> 100.134.219.193 ->
100.134.208.168 -> 100.192.71.190 -> 100.230.22.123`) while the public
egress was a different, also rotating 106.222.x address
(`106.222.226.175 -> 106.222.224.104 -> 106.222.225.44 ->
106.222.226.146`). The router was in `IPAddress_Auto` mode, Caddy logged
zero external requests, and `media.anisparvez.in` pointed at the dead
`122.163.124.18`.

Airtel's earlier reply quoted `100.134.226.11` as the static IP. That
address was never configured on the router and is not reachable from the
internet. It falls in `100.128.0.0/9`, announced by **AS21928 (T-Mobile
USA)**, not Airtel. The 100.x pool Airtel was handing out was
Airtel-internal, not globally routed to the line.

On 2026-10-22 the line was moved to IPoE with a static address. The router
form now shows:

  * `RN_IPAddr = 171.50.176.119`
  * `RN_Subnet = 255.255.255.0`
  * `RN_Gateway = 171.50.176.1`
  * `RN_IP` radio = **Static** (`IPAddress_Static`, value 0)
  * `IPArr[3] = "171.50.176.119"`, `isDynamicArr[3] = "0"`
  * IPoE connection `Internet_IPoE` is active and the default WAN
  * DNS: `117.96.122.59`, `59.144.144.100`

## THE PROOF

WAN and egress now agree:

    Router WAN (UPnP) : 171.50.176.119
    Public egress     : 171.50.176.119
    Egress (DNS check): 171.50.176.119
    Carrier NAT       : NO
    WAN ASN           : AS24560 Bharti Airtel
    Egress ASN        : AS24560 Bharti Airtel

RIPE Stat reports `171.50.176.0/24` announced by AS24560.

Inbound was proven before Caddy was started, with a temporary listener on
port 80. An external fetch (`r.jina.ai`) to `http://171.50.176.119/`
returned `inbound-probe-ok from 192.168.1.16` at 2026-10-22 12:27:32 IST,
then the listener exited and released port 80.

After Caddy started, the diagnostic reports both ports reachable:

    Inbound :80       : REACHABLE
    Inbound :443      : REACHABLE

External HTTPS returns the Rust health payload:

    {"engine":"rust","service":"media-server-api","status":"healthy","version":"0.1.0"}

and the SPA root loads ("Anis' Home Media Server", library, featured
title).

## WHAT WAS CHANGED

  * Cloudflare DNS: the `media` A record was changed from the dead
    `122.163.124.18` to `171.50.176.119`, keeping it DNS-only
    (`proxied=false`). Verified at `austin.ns.cloudflare.com`,
    `marjory.ns.cloudflare.com`, `1.1.1.1` and `8.8.8.8`.
  * Caddy: `MediaServerCaddy` was started and its startup type set back
    to **Automatic**. Certificate: Let's Encrypt `CN=media.anisparvez.in`,
    issued by `CN=YE2`, valid 2026-10-19 00:47:08 -> 2027-01-17 00:47:07.
  * Router: **Enable NAT loopback** was checked on the NAT General page
    (it had been reset by the reprovision). Internal requests to
    `media.anisparvez.in` now hairpin to Caddy instead of hitting the
    router's login page.
  * The router's port-forward table is unchanged and intact:
    `HTTP 80 -> 192.168.1.16:80`, `HTTPS 443 -> 192.168.1.16:443`.
    Nothing else is forwarded.

## VERIFIED

  * Internal `https://media.anisparvez.in/health` -> HTTP 200, Rust JSON,
    `ssl_verify_result=0`.
  * Internal `http://media.anisparvez.in/` -> 308 to HTTPS.
  * External `https://media.anisparvez.in/health` -> HTTP 200, Rust JSON.
  * External SPA root loads.
  * `MediaServerRust` on `127.0.0.1:8000` -> HTTP 200.
  * Caddy: Running, Automatic.

## TIMELINE

  * 2026-10-21: carrier NAT proven; Caddy disabled; public ingress dead.
  * 2026-10-22 ~12:20 IST: IPoE static address observed on the router.
  * 2026-10-22 12:27:32 IST: external port-80 probe reached the temporary
    listener.
  * 2026-10-22 12:30:39 IST: external HTTPS health check returned 200.
  * 2026-10-22 12:40 IST: handoff written.

## WHAT REMAINS

  * The static IP should be billed from **2026-10-22**, not earlier. The
    owner is sending Airtel a written request with the evidence above.
  * `docs/PROJECT_STATUS.md`, `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md`
    and the AGENTS.md architecture diagram still describe the old
    Cloudflare-tunnel/static-IP state. They were not updated here.
  * `scripts/router_port_forward.ps1` has a pre-existing line-ending
    modification (M) in the working tree; it was not touched or committed.
  * The Cloudflare API token in `Caddyfile` is still a live credential in
    plaintext; the known rotation/scoping issue remains.

## FILES

  * `scripts/get-router-wan.ps1` (new) - UPnP WAN, public egress, CGNAT
    verdict, ASN ownership and inbound reachability in one run.

        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-router-wan.ps1

    It reports reachability only when a local listener exists on 80/443;
    otherwise it says NOT TESTED rather than a false "unreachable".
