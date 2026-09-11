# Agent Instructions

## Project Context

This repository is the user's media server project (`media-server-1`). It is a Flask/Django-based media server and is developed locally in Kali Linux using VS Code and AI coding agents.

## Remote Access Setup

The application currently runs locally on `127.0.0.1:8000`.

The home Internet connection is behind Airtel CGNAT, so direct inbound IPv4 connections and ordinary router port forwarding are not the chosen solution.

A Cloudflare **named tunnel** is now configured for the purchased domain `anisparvez.in`:

```text
Internet
   -> https://media.anisparvez.in
   -> Cloudflare DNS / Tunnel
   -> named tunnel: media-server
   -> cloudflared running on Kali
   -> http://127.0.0.1:8000
   -> Media server
```

The named tunnel is started from a normal Kali terminal with:

```bash
cloudflared tunnel run media-server
```

The Cloudflare DNS route was created with:

```bash
cloudflared tunnel route dns media-server media.anisparvez.in
```

The tunnel ingress configuration routes `media.anisparvez.in` to `http://127.0.0.1:8000`.

Tunnel credential JSON files under `~/.cloudflared/` are secrets and must never be committed or exposed.

A temporary Quick Tunnel was used earlier for initial testing, but agents should treat the **named tunnel + custom domain** as the current architecture.

## Terminal Responsibilities

- **VS Code terminal:** run and manage the media server application.
- **Normal Kali terminal:** run and keep the `cloudflared` named tunnel process alive.

## Security / Deployment Notes

- The custom hostname provides stable addressing but does not itself provide application authentication.
- Production WSGI deployment is powered by Gunicorn (`gthread` worker with 8 threads) managed by systemd (`media-server.service`), wrapped with Werkzeug's `ProxyFix` middleware to handle Cloudflare tunnel and reverse proxy headers (`X-Forwarded-For`, `CF-Connecting-IP`).
- Prefer configuration through environment variables or an appropriate secrets mechanism.
- Review Cloudflare's current service-specific video/large-file policies before using the public proxy path to deliver the entire media library.

## Existing Documentation

See `docs/REMOTE_ACCESS_CLOUDFLARE_TUNNEL.md` for the detailed setup, DNS configuration, tunnel configuration, commands, and remote-access history.

## Agent Behavior

Before changing remote-access behavior, read the remote-access documentation and this file. Preserve the CGNAT-compatible architecture unless the user explicitly asks to replace it.

When making changes, never expose or commit the tunnel credential JSON, API keys, tokens, passwords, or other secrets.
