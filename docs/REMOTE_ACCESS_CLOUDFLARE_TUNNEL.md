# Remote Internet Access via Cloudflare Quick Tunnel

## Goal
Expose the local Flask media server to the Internet despite an Airtel connection that uses CGNAT and does not provide a static public IPv4 address.

## Current application
- Repository: `anis7t/media-server`
- Local project directory used during development: `media-server-1`
- Flask media server is running locally on port `8000`.
- Local verification succeeded with:

```bash
curl http://127.0.0.1:8000
```

The command returned the media server HTML, confirming the Flask application was reachable locally.

## Why normal port forwarding is not suitable
The home router's WAN IP was observed to differ from the public IP seen by Internet services. This is consistent with the connection being behind Carrier-Grade NAT (CGNAT).

With CGNAT, inbound Internet connections generally cannot be forwarded directly from the public Internet to the home router using normal router port forwarding. A static public IPv4 address is also not required for the solution below.

## Free solution used
A Cloudflare **Quick Tunnel** (`trycloudflare.com`) was used. This requires no purchased domain, no static public IP, and no router port-forwarding rule.

Traffic path:

```text
Internet
   -> Cloudflare Quick Tunnel (*.trycloudflare.com)
   -> outbound tunnel from the Kali Linux machine
   -> local Flask server
   -> 127.0.0.1:8000
```

## Installation
`cloudflared` was not available from the configured Kali APT repositories (`apt install cloudflared` returned `Unable to locate package cloudflared`).

The official Debian package was therefore downloaded from Cloudflare's GitHub releases and installed with `dpkg`:

```bash
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
```

The version command completed successfully.

## Starting the tunnel
The tunnel was started from a **normal Kali Linux terminal**, while the Flask application remained running from the **VS Code terminal**:

```bash
cloudflared tunnel --url http://127.0.0.1:8000
```

Cloudflare returned a temporary public HTTPS URL under `https://*.trycloudflare.com`.

## Result
The generated public URL was tested successfully from outside the local network, confirming that the media server was accessible over the Internet while the home connection remained behind CGNAT.

## Operational notes
- Keep the `cloudflared` process running; stopping that process stops the Quick Tunnel.
- The Quick Tunnel URL is temporary/random and is not intended to be a permanent hostname.
- No Airtel router configuration was required.
- No paid domain or static public IP was required.
- The public URL itself should not be treated as authentication. Anyone who obtains the URL may be able to access the application, so authentication/access control should be added before regular or wider use.
- The Flask development server should not be treated as the final production Internet-facing deployment. A production WSGI server and appropriate security controls should be considered for long-term use.

## Terminal separation used
**VS Code terminal:** run and manage the `media-server-1` Flask application.

**Kali terminal:** run `cloudflared` and keep the tunnel process alive.

This separation keeps application development and Internet tunneling independent.

## Next recommended improvements
1. Add authentication/access protection to the media server before sharing the public URL.
2. [Completed] Production WSGI deployment is live using Gunicorn (`gthread` worker, 8 threads, 120s streaming timeout) with `ProxyFix` middleware and managed by systemd (`media-server.service`).
3. For a permanent public hostname later, replace the Quick Tunnel with a named Cloudflare Tunnel/domain or another stable reverse-tunnel/VPS architecture.
