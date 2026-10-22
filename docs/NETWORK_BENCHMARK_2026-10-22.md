# Network Benchmark — 2026-10-22

**Status:** Completed. Public/LAN benchmark taken after the static-IP cutover.

**Host:** `E:\MediaServer` — Rust Axum on `:8000`, Caddy on the public static IP,
PostgreSQL 18.4, media on `D:\Flicks`, runtime/cache on `E:`.

**Important:** the public-domain tests in this run were made **from the server's own laptop**.
They are **hairpin** measurements: the request leaves the laptop, goes through the LAN/router and
Caddy, and comes back to the same host. They measure the local path, **not** the ISP. The
`192.168.1.16` tests are **loopback** from the server to its own LAN address, so the high Gbps
numbers are RAM/loopback, not NIC throughput.

## 1. ISP baseline

| Source | Download | Upload | Notes |
| --- | ---: | ---: | --- |
| Cloudflare speed test | 197 Mbps | 109–114 Mbps | Best single-stream upload observed. |
| Ookla (Sikka server) | 203–206 Mbps | 61–79 Mbps | Endpoint/server dependent. |
| Airtel Lucknow Ookla server | 198 Mbps | 4.5–4.9 Mbps | Endpoint-capped; **excluded** from the line estimate. |
| Parallel uploads, best case | — | ~120–160 Mbps aggregate | Observed best case; not a guaranteed plan rate. |

The line behaves like a **200/100-class** service. It is **not proven to be 200/200**. The upload
is provisioned below 200 Mbps. If the plan is 200/200, raise an Airtel ticket; if the plan is
200/100, the upload is at plan. Do not describe the line as a confirmed 200/200 service.

The Airtel Lucknow server's 4.5–4.9 Mbps upload is an endpoint problem, not a line measurement.
It was excluded rather than averaged in.

## 2. HTTP latency

| Path | `/health` | HLS master | Notes |
| --- | ---: | ---: | --- |
| LAN, from the server | 1.4 ms | 4.8 ms | Local path. |
| Public domain, from the laptop | 35.3 ms | 37.6 ms | Mostly local DNS + TLS; hairpin path. |
| Public TCP connect | 2.7 ms | — | Connect only. |
| Server processing | 1.5–4.7 ms | — | Origin handling. |

The public ~35 ms is **not** a WAN RTT measurement from a remote client. It is dominated by local
DNS/TLS setup on this host and the hairpin route. A true external client may see a different
number.

## 3. Throughput

| Path | Result | Notes |
| --- | ---: | --- |
| Public hairpin HLS | 627–736 Mbps | LAN/router/Caddy path, not ISP. |
| LAN loopback HLS, cold | 1.386 Gbps | `192.168.1.16` from the server = loopback. |
| LAN loopback HLS, warm | 4.29 Gbps | RAM/loopback; not NIC-bound. |
| Direct file, `D:` | 455–732 Mbps | HDD-bound; file-dependent. |
| `E:` SSD sequential | 211–228 MB/s | Runtime/cache volume. |
| `D:` HDD sequential | 56–91 MB/s | Cold media volume; file-dependent. |

The public hairpin HLS number is high because the traffic never leaves the host's LAN path. It
does **not** mean a remote viewer can pull 627–736 Mbps. The remote viewer is limited by the ISP
uplink below.

## 4. Remote streaming capacity

At roughly **100 Mbps usable uplink**:

| Stream | Approx. bitrate | Concurrent viewers |
| --- | ---: | ---: |
| 4K HLS | ~14 Mbps | ~5–7 |
| 4K direct | ~18 Mbps | ~4–5 |
| 1080p | ~5–7 Mbps | ~15–22 |

These are estimates with normal headroom, not guarantees. The actual concurrency depends on the
title's bitrate, the client's buffer, the ISP's real upload at that moment, and whether the stream
is direct or transcoded.

## 5. External reachability

- `r.jina.ai` fetched the public `/health` endpoint and returned HTTP 200, so the hostname is
  reachable from an external network.
- Fetching the HLS master through `r.jina.ai` returned HTTP 422. That is the fetch service's
  limitation on the media response, not a failure of the origin. It is not a throughput test.
- No true external client throughput test was possible. The remote mobile fleet would require
  user consent; a local phone was not available. The next honest test is a download/upload from a
  device on a different network (mobile data), with the server's egress measured at the same time.

## 6. Ingress and Caddy `admin off`

The public origin is the static IP **`171.50.176.119`**, served by Caddy. DNS, the certificate, and
the reverse proxy to `127.0.0.1:8000` are working. Only **443** and **80** are forwarded from the
internet; the old **8000** forward was removed. Plain HTTP to the origin must stay closed.

`E:\MediaServer\Caddyfile` contains **`admin off`** in the global block. It means:

- Caddy's admin API (default `127.0.0.1:2019`) is **disabled**.
- `caddy reload`, `caddy stop`, and dynamic config changes through the admin API will fail.
- To change the Caddyfile, edit it and **restart the `MediaServerCaddy` service** (or run Caddy
  with the new config). There is no reload endpoint to call.
- `admin off` does **not** impose a request-body limit. Caddy's `reverse_proxy` streams request and
  response bodies. The 2 MB upload cap found below is **Axum's** default, not Caddy's.

The Airtel static-IP email is drafted but **unsent**; do not send it unless asked.

## 7. Axum upload limit (follow-up finding)

The Rust backend is Axum 0.8 with the `multipart` feature. There is **no** `DefaultBodyLimit`,
`RequestBodyLimitLayer`, or equivalent in `rust/src`. Axum's default **2 MB** body limit therefore
applies to extractors such as `Multipart` and `Bytes`.

Measured against the live service:

| Test | Result |
| --- | --- |
| 1.5 MB subtitle upload | Succeeded. |
| 3 MiB subtitle upload | Rejected: HTTP **400** `{"error":"Error parsing \`multipart/form-data\` request","status":400}`. The `Multipart` handler maps the body-limit error to 400 rather than 413. |
| `POST /api/upload` | 404 — no route. |
| `POST /api/upload/chunk/init` | 404 — no route. |
| `POST /api/upload-subtitle/{filename}` | Exists and works; this was the 1.5 MB success. |

Consequence: the Flask chunk size was **8 MiB**, so a port that reused that chunk size would fail
on the first chunk under the default 2 MB cap. The fix is **per-route** limits, not a global
`DefaultBodyLimit::disable()`: the latter would turn every JSON and multipart route into an
unbounded-body DoS surface. The proposed limits and the upload-port plan are in
[`Handoffs/2026-10-22_13-50_opencode_network-benchmark-and-upload-port.md`](../Handoffs/2026-10-22_13-50_opencode_network-benchmark-and-upload-port.md).

## 8. Caveats

- Public tests from the laptop are hairpin; they are not an ISP measurement.
- `192.168.1.16` from the server is loopback; the Gbps figures are not NIC throughput.
- No true wired LAN client was available; the laptop is the server.
- No true external client throughput was measured; the remote fleet requires consent.
- The ISP rate varies by time, endpoint, and direction. The Cloudflare and Ookla results disagree
  on upload because of endpoint effects.
- The Airtel Lucknow upload result is endpoint-capped and excluded.
- The `D:` HDD direct-file rate is file- and cache-dependent; the `E:` SSD is the runtime/cache
  volume.
- These numbers are a snapshot. Re-measure after any Caddy, router, ISP, or storage change.

## 9. Reproduce (outline)

- Public HLS/direct: byte-range and segment `curl` requests against
  `https://media.anisparvez.in/...` from the laptop; record the wall time and bytes.
- LAN loopback: the same requests against `http://192.168.1.16:8000/...` from the server.
- Direct file: `curl` against `/media/<filename>` with a range; compare `D:` and `E:` files.
- Latency: `curl -w` for `time_namelookup`, `time_connect`, `time_starttransfer`, and total against
  `/health` and the HLS master.
- ISP: Cloudflare speed test and Ookla; do not use the Airtel Lucknow server for upload.
- Upload cap: `curl -F "subtitle=@<file>"` against `/api/upload-subtitle/<filename>` at 1.5 MB and
  3 MiB; check the status code and body.

The detailed, resumable implementation context is in the handoff linked above.

## 10. Post-benchmark update — upload port implemented (2026-10-22)

The measurements above are unchanged; this note records what happened after them.

The two 404 rows in §7 are a snapshot of the service **before** the port. The native Rust/Axum
upload routes now exist:

| Route | Status after the port |
| --- | --- |
| `POST /api/upload` | Implemented, admin-gated, 256 MiB single-file compatibility cap. |
| `POST /api/upload/chunk/init` | Implemented, admin-gated, 20 GiB resumable sessions. |
| `GET` / `POST` / `DELETE /api/upload/chunk/{id}` | Implemented, admin-gated; 8 MiB chunks; `409` reports `current_offset`. |
| `POST /api/upload/chunk/{id}/complete` | Implemented, admin-gated; verifies byte count and indexes the file. |
| `/api/upload-subtitle/{filename}` | Still works; its route limit is now **16 MiB**. |

**The 2 MB finding still governs the design.** Axum's global default remains 2 MB; the upload
routes carry per-route `DefaultBodyLimit` values instead of disabling the global cap. The final
values are 256 MiB for the single-file route, 8 MiB + 64 KiB for a chunk request, and 16 MiB for
subtitles. The chunk route therefore accepts the Flask-era 8 MiB chunk that the default limit
would have rejected, without turning the JSON API into an unbounded body sink.

The Caddy `admin off` setting is still unrelated to request-body size: it disables Caddy's local
admin API on `127.0.0.1:2019`, not a proxy body limit. The 2 MB cap was Axum's, and it is now
overridden only where uploads need it.

Implementation, testing, and deployment details are in
[`MEDIA_UPLOAD_PORT_2026-10-22.md`](MEDIA_UPLOAD_PORT_2026-10-22.md).
