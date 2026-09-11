# Remote Internet Access via Cloudflare Tunnel

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

## Initial Quick Tunnel setup
A Cloudflare **Quick Tunnel** (`trycloudflare.com`) was first used for testing. This required no purchased domain, no static public IP, and no router port-forwarding rule.

Initial traffic path:

```text
Internet
   -> Cloudflare Quick Tunnel (*.trycloudflare.com)
   -> outbound tunnel from the Kali Linux machine
   -> local Flask server
   -> 127.0.0.1:8000
```

The Quick Tunnel was tested successfully from outside the local network.

## cloudflared installation
`cloudflared` was not available from the configured Kali APT repositories (`apt install cloudflared` returned `Unable to locate package cloudflared`).

The official Debian package was therefore downloaded from Cloudflare's GitHub releases and installed with `dpkg`:

```bash
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
```

The installation completed successfully.

## Domain and DNS setup
A personal domain, `anisparvez.in`, was purchased from GoDaddy.

Cloudflare was configured as the authoritative DNS provider by replacing the GoDaddy nameservers with the nameservers assigned by Cloudflare. DNSSEC was confirmed to be disabled at GoDaddy before the nameserver change.

The Cloudflare zone is now active.

GoDaddy remains the registrar; Cloudflare manages DNS for the domain.

## Named Cloudflare Tunnel
A named tunnel was created:

```bash
cloudflared tunnel create media-server
```

Tunnel name:

```text
media-server
```

Tunnel ID:

```text
cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
```

The tunnel credential file was created at:

```text
~/.cloudflared/cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f.json
```

**The credential JSON is secret and must never be committed to Git or pasted into documentation.**

The installed `cloudflared` version reported a recommendation to upgrade from `2026.9.0` to `2026.9.1`; this is a warning, not a tunnel-configuration failure.

## Custom hostname routing
The domain hostname `media.anisparvez.in` was attached to the named tunnel with:

```bash
cloudflared tunnel route dns media-server media.anisparvez.in
```

Cloudflare confirmed:

```text
Added CNAME media.anisparvez.in which will route to this tunnel
```

The intended public traffic path is now:

```text
Internet
   -> https://media.anisparvez.in
   -> Cloudflare DNS / Tunnel
   -> named tunnel: media-server
   -> cloudflared on Kali
   -> http://127.0.0.1:8000
   -> Flask media server
```

## Current tunnel configuration
A configuration file was created at:

```text
~/.cloudflared/config.yml
```

Configuration:

```yaml
tunnel: cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f
credentials-file: /home/iamroot/.cloudflared/cfd34bc3-8aee-4afa-9c7a-42bbdc10b57f.json

ingress:
  - hostname: media.anisparvez.in
    service: http://127.0.0.1:8000

  - service: http_status:404
```

The configuration was validated successfully with:

```bash
cloudflared tunnel ingress validate
```

Output:

```text
Validating rules from /home/iamroot/.cloudflared/config.yml
OK
```

## Running the named tunnel
Start the named tunnel from a **normal Kali Linux terminal**:

```bash
cloudflared tunnel run media-server
```

Keep this process running while remote access is needed.

The Flask application should be run and managed separately from the **VS Code terminal**.

## Terminal separation used
**VS Code terminal:** run and manage the `media-server-1` Flask application.

**Kali terminal:** run `cloudflared` and keep the tunnel process alive.

This separation keeps application development and Internet tunneling independent.

## Operational commands
Start the current named tunnel:

```bash
cloudflared tunnel run media-server
```

Stop a foreground tunnel with:

```text
Ctrl+C
```

Stop a running cloudflared process from another terminal:

```bash
pkill cloudflared
```

Check whether cloudflared is running:

```bash
pgrep -a cloudflared
```

For the current development workflow, keeping the tunnel in a dedicated Kali terminal is preferred so tunnel errors remain visible.

## Security notes
- Never commit the tunnel credential JSON file.
- Never commit API keys, passwords, tokens, or other secrets.
- The custom domain is stable, but a hostname being stable does not itself provide authentication.
- Authentication/access control should be added before wider public sharing.
- The Flask development server should not be treated as the final production Internet-facing deployment. A production WSGI server and appropriate security controls should be considered for long-term use.

## Video / large-file delivery consideration
The public Cloudflare proxy path should not automatically be treated as a general-purpose CDN for the entire personal movie/TV library. Cloudflare's current service-specific terms and documentation place restrictions on serving video and disproportionate amounts of large files through the public CDN/proxy on Free, Pro, and Business plans. Review the current Cloudflare policy before designing high-volume media delivery through the public hostname.

For private personal access, consider a private-network/VPN-oriented architecture so the web application and media transport can be separated appropriately.

## Next recommended improvements
1. Verify `https://media.anisparvez.in` externally with the named tunnel running.
2. Add authentication/access protection to the media server before wider sharing.
3. Install the named tunnel as a managed system service so it can start automatically after boot.
4. Review the media-delivery architecture before using the public Cloudflare proxy to serve large video files at scale.
