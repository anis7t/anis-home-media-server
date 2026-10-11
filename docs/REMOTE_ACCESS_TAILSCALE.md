# Remote Access: Cloudflare Tunnel vs Tailscale

Date: 2026-10-12
Measured on: `anis7t` (Windows host, Airtel Xstream ONT `AOT5222ZY`, public IP `106.222.227.4`)
Branch: `investigate/wan-throughput-bottleneck`

This supersedes nothing in `REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` — that document remains the
record of how the tunnel was built. This one records **why it is slow**, what the alternative
is, and what was actually measured.

---

## 1. The headline

| Path | URL | Measured | Cost |
|---|---|---|---|
| Cloudflare tunnel | `https://media.anisparvez.in` | **2.8 MB/s** (22 Mbps) | $0 |
| **Tailscale** | `http://media-server.tail7d5bf9.ts.net:8000` | **23.6–32.6 MB/s** (189–261 Mbps) | **$0** |
| The line itself | — | 19.7 MB/s up / 24 MB/s down | — |

**The line is not the bottleneck. The Cloudflare path is.** Ookla (result ID 19777478291):
download **192.70 Mbps**, upload **157.70 Mbps**, ping **6 ms** — effectively symmetric.

The tunnel delivers ~7x less than the uplink feeding it. Everything below explains why.

---

## 2. Line capacity (Ookla, in-browser, 2026-10-12)

```
Download : 192.70 Mbps
Upload   : 157.70 Mbps
Ping        6 ms
Result ID 19777478291
```

Repeated for contrast, all pointing at Cloudflare's nearest edge:

| Test | Result |
|---|---|
| Cloudflare download (`speed.cloudflare.com/__down`) | 15.8–20.0 MB/s |
| Cloudflare upload (`speed.cloudflare.com/__up`) | 1.10–1.66 MB/s (IPv4 and IPv6) |

Note the asymmetry **within Cloudflare itself**: download from the edge is fast, upload to it is
not. A fast download and a slow upload over the same link is the signature of a congested
*upstream* transit path, not a slow line.

---

## 3. Why the tunnel is slow — the peering problem

Cloudflare has no peering agreement with Airtel or Jio, which together hold >75% of the Indian
market. Traffic is therefore routed to distant edges rather than Mumbai/Chennai.

Confirmed at the infrastructure level, from the tunnel's own API:

```
colo del03  (Delhi)     colo ccu02  (Kolkata)
colo del05  (Delhi)     colo ccu02  (Kolkata)
```

and from a live response header:

```
CF-RAY: a48fd1e4ae5fc913-MRS      ← Marseille, France
```

A user in India being served from **Marseille** is the whole problem. Latency to the edge is
fine (28–34 ms to `1.1.1.1`, 0% loss) — it is bandwidth that is missing.

Corroborating community reports, all matching this symptom set:

- `punits.dev/blog/cloudflare-latency-india/` — Indian ISP users routed to Amsterdam/Frankfurt
- `community.cloudflare.com` — "1.1.1.1 Unreachable on Airtel Broadband (India)", Apr 2026
- `broadband.forum` — "contact airtel to fix their cloudflare peer issue"

**This is not fixable by configuration.** No cache rule, compression setting, protocol change or
tunnel option alters a peering agreement.

---

## 4. CGNAT — why DNS-only hosting is impossible

Verified against the ONT's decrypted TR-069 config (`zyxel_backup_restore.py full-backup`):

```
PPPoE interface (ppp111, VLAN 100):  gateway 100.69.8.129
VoIP  interface (nas0_660, VLAN 660): 100.69.8.232
```

Both are inside **`100.64.0.0/10` (RFC 6598 shared space)**, which is never routable on the
public internet. Airtel translates between those and the internet-visible `106.222.227.4`
(a CGNAT pool allocated from routable-looking space — which is exactly why the address alone
proves nothing).

**Consequence:** a DNS record can never target the home connection. Port forwarding on the ONT
changes nothing, because there is no address the internet can send inbound packets to. Any
public hostname must terminate at a relay that can reach you — Cloudflare, or a VPS.

> A CGNAT pool can be allocated from ordinary-looking routable space. "The public IP is not in
> 100.64/10" is therefore **not** evidence against CGNAT. The router's own config is.

---

## 5. Tailscale — what is installed and verified

```
Version   1.104.1
Service   Running, StartType Automatic (survives reboot)
Node      media-server
MagicDNS  media-server.tail7d5bf9.ts.net
Tailnet   100.102.146.87  (fd7a:115c:a1e0::c001:92e1)
Adapter   Private network category -> matches the Tailscale-In inbound allow rules
```

Waitress already binds `0.0.0.0:8000`, so no configuration change was needed to expose it.

### End-to-end verification over the tailnet — 10/10

```
[PASS] homepage                                HTTP 200, 194567 bytes
[PASS] API /api/devices (JSON)                 HTTP 200, valid JSON
[PASS] range request, direct play              HTTP 206, Content-Range: bytes 0-1048575/2558024294
[PASS] open-ended range (player seek)          HTTP 206, 2556975718 bytes
[PASS] range near EOF (tail of a 2.4GB file)   HTTP 206, 1000001 bytes
[PASS] HLS playlist (3 attempts)               [200, 200, 200]
[PASS] HLS segment fetch                       HTTP 200, 126148 bytes
[PASS] movie detail page                       HTTP 200, 147065 bytes
[PASS] unknown movie -> styled 404             HTTP 404, styled page rendered
[PASS] sustained throughput (12s)              268 MB in 11.4s = 188.6 Mbps (23.58 MB/s)
```

### Two apparent failures that were NOT defects

Both were my test's error, recorded because "it was green" is not the same as "it is correct":

1. **HLS playlist 503** — a live transcode was in flight. The playlist now returns 200
   consistently. A cache being written is expected to 503.
2. **`/player/<filename>` 404** — **this route does not exist.** The only page route is
   `/movie/<path:filename>` (`app/routes/pages.py:60`). The 404 is the app's own styled page.
   The test asserted a URL that was never supposed to work.

---

## 6. What each option is, and is not

Tailscale is **not** a replacement for the public-hostname function. It is a replacement for the
**transport**:

| | Cloudflare tunnel | Tailscale |
|---|---|---|
| Reachable by anyone on the internet | Yes | No — only tailnet devices |
| Needs the user to install a client | No | Yes |
| Public URL | Yes | No |
| Works behind CGNAT with no public IP | Yes | Yes |
| Speed | 2.8 MB/s | 23.6–32.6 MB/s |

Both can run at once. That is the recommended configuration: `media.anisparvez.in` stays live
and universal (and unauthenticated — see §8), while Tailscale provides the fast path.

---

## 7. Making `media.anisparvez.in` itself faster

Impossible at $0 — CGNAT forbids self-hosting publicly (§4). The options that would work:

| Approach | Cost | Note |
|---|---|---|
| Indian VPS (Mumbai/Delhi), DNS-only | ~$4/mo | Serves the real 157 Mbps uplink; no Cloudflare in the path |
| Cloudflare R2 | ~$0.75/mo for 60 GB | Edge-served; **but** the project's own doc flags Cloudflare's terms on video via the proxy |
| Cloudflare Stream | $10s–$50s/mo | Per-minute storage **and** delivery; poor fit for a self-hosted library |

Library size measured for these estimates: **60 GB** of transcoded HLS across 23 titles; 117 GB
of raw media on `D:`.

---

## 8. Security note

`media.anisparvez.in` is publicly reachable with **no authentication**, and
`REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` records this as an open item. Tailscale incidentally
*reduces* exposure, because a tailnet is private by default — but that is a side effect of a
transport choice, not a security control. Anyone you do not enrol on the tailnet still reaches
the server through the tunnel, unchallenged.

---

## 9. Measurement discipline

Numbers in this document were taken as follows, and the failures are recorded rather than hidden:

- Ookla in a real browser via Chrome DevTools (the CLI installer is 403/429 from this network;
  `downloads.ookla.com` is NXDOMAIN from every resolver including Cloudflare and Google).
- Throughput measured with an **independent stopwatch against bytes written to disk**, because a
  `curl -m` timeout truncation once produced an absurd 514 MB/s "through Cloudflare" figure.
- The first speedtest-server sweep was misleading: the nearest reachable Ookla servers were in
  **Pakistan (2,296–2,474 km)**, which alone accounted for a 6.5 Mbps upload reading.
- AdGuard DNS (`94.140.14.14/15`) was investigated and **cleared** — the hosts it appeared to
  block return NXDOMAIN from Cloudflare and Google resolvers too. It was not filtering anything.