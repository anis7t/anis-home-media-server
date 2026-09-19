# Remote Internet Access via Cloudflare Tunnel

This document describes a generic Cloudflare Tunnel deployment for the Media Server. Personal hostnames, tunnel IDs, usernames, credential locations, and workstation-specific paths are intentionally omitted.

## Goal

Expose the local Flask media server through Cloudflare Tunnel without requiring direct inbound access to the home network.

## Local application

The Media Server runs locally on port `8000` by default.

```bash
curl http://127.0.0.1:8000
```

## Temporary testing

```bash
cloudflared tunnel --url http://127.0.0.1:8000
```

This produces a temporary `trycloudflare.com` hostname.

## Named tunnel

```bash
cloudflared tunnel create <tunnel-name>
```

Keep the tunnel ID and credential JSON outside Git. A typical credential location is:

```text
~/.cloudflared/<tunnel-id>.json
```

**The credential JSON is secret and must never be committed or pasted into documentation.**

## Custom hostname

```bash
cloudflared tunnel route dns <tunnel-name> <media-hostname>
```

Typical traffic flow:

```text
Internet
   -> HTTPS hostname
   -> Cloudflare DNS / Tunnel
   -> cloudflared
   -> http://127.0.0.1:8000
   -> Flask media server
```

Do not publish a real personal hostname in generic project documentation.

## Example configuration

```yaml
tunnel: <cloudflare-tunnel-id>
credentials-file: ~/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: <media-hostname>
    service: http://127.0.0.1:8000

  - service: http_status:404
```

Validate the configuration:

```bash
cloudflared tunnel ingress validate
```

Run the named tunnel:

```bash
cloudflared tunnel run <tunnel-name>
```

## Security notes

- Never commit tunnel credentials.
- Never commit API keys, passwords, tokens, private keys, or session secrets.
- A public hostname provides connectivity, not application authentication.
- Add authentication/access control before broader remote sharing.
- Prefer binding the origin to localhost when Cloudflare is the external access layer.
- Use a production WSGI server for long-running deployments.

## Video delivery

Before using Cloudflare as the public path for substantial video traffic, review the current Cloudflare product limits, terms, and architecture guidance for the deployment's plan. A tunnel that works technically is not automatically the right design for unrestricted large-file delivery.

For private access, a VPN/private-network architecture may be more appropriate depending on the deployment.

## Generic checklist

1. Run the application on `127.0.0.1:8000`.
2. Create/configure a named tunnel.
3. Keep tunnel credentials outside Git.
4. Attach a deployment-specific hostname.
5. Validate ingress rules.
6. Add authentication/access control.
7. Configure managed startup if unattended operation is required.
8. Re-test media delivery after infrastructure changes.
