# Agent Instructions

## Project Context

This repository is the user's media server project (`media-server-1`). It is a Flask/Django-based media server and is developed locally in Kali Linux using VS Code and AI coding agents.

## Remote Access Setup

The application currently runs locally on `127.0.0.1:8000`.

The home Internet connection is behind Airtel CGNAT, so direct inbound IPv4 connections and ordinary router port forwarding are not reliable/available.

Remote access was successfully established using a **Cloudflare Quick Tunnel**:

```text
Internet
   -> Cloudflare Quick Tunnel (*.trycloudflare.com)
   -> cloudflared running on Kali
   -> http://127.0.0.1:8000
   -> Media server
```

The tunnel is started from a normal Kali terminal with:

```bash
cloudflared tunnel --url http://127.0.0.1:8000
```

The generated `trycloudflare.com` hostname is temporary and only works while the `cloudflared` process is running. Do not hard-code or commit the generated hostname.

## Terminal Responsibilities

- **VS Code terminal:** run and manage the media server application.
- **Normal Kali terminal:** run and keep the `cloudflared` tunnel process alive.

## Security / Deployment Notes

- A Quick Tunnel does not automatically provide application authentication. Treat the generated public URL as an access credential and do not publish it unnecessarily.
- Production WSGI deployment is powered by Gunicorn (`gthread` worker with 8 threads) managed by systemd (`media-server.service`), wrapped with Werkzeug's `ProxyFix` middleware to handle Cloudflare tunnel and reverse proxy headers (`X-Forwarded-For`, `CF-Connecting-IP`).
- Prefer configuration through environment variables or an appropriate secrets mechanism.

## Existing Documentation

See `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` for the detailed setup and history of the remote-access configuration.

## Agent Behavior

Before changing remote-access behavior, read the remote-access documentation and this file. Preserve the CGNAT-compatible architecture unless the user explicitly asks to replace it.

When making changes, avoid exposing or committing the temporary Cloudflare URL or any credentials.
