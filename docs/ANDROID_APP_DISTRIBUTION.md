# Android App Distribution

Last updated: 2026-10-05

The server distributes one universal Android APK for Android phones, Android TV,
and Fire TV. The public web entry point is:

- `https://media.anisparvez.in/download`

The page is intentionally APK-only. It does not implement or advertise a PWA
installation flow.

## Current production release

| Field | Value |
|---|---|
| Version | `1.2.19` |
| Version code | `139` |
| Package | `in.anisparvez.media_server_client` |
| Minimum Android SDK | `24` |
| Target Android SDK | `36` |
| APK size | `102,222,801` bytes (97.5 MB) |
| SHA-256 | `b7cbcb036dd2066e844d0313d574729505e0630fbda7cc4b6dff974b3b885a77` |
| Release notes | Production Android client release with mobile and Android TV support. |

The release metadata is stored in `updates/production/manifest.json` on the
host. APK files and manifests under `updates/` are deployment artifacts and are
ignored by Git; `updates/version_registry.json` is the tracked release counter.

## User download flow

1. A user selects **Get the app** from a site header/action rail or **Android
   app** in a footer.
2. `/download` renders the production release metadata.
3. **Download APK** requests the production-only endpoint:
   `/api/app/download?channel=production`.
4. The endpoint provides an attachment with byte-range support, which allows
   interrupted or resumable downloads.

The developer channel is not linked from the public site.

## Publishing a production release

Use the repository's verified release command. It builds the APK, assigns a
monotonic version code, validates the APK identity, calculates the SHA-256,
and writes the channel manifest atomically:

```powershell
.\venv\Scripts\python.exe scripts\release_android.py `
  --channel production `
  --version 1.2.20 `
  --version-code 140 `
  --notes "Production Android client release."
```

Do not publish a plain `flutter build apk --release` output manually. The
release script ensures the APK's package ID, version name, version code, SDK
levels, and manifest agree.

Signing uses the local ignored `flutter_client/android/key.properties` file and
the configured release keystore. Never commit either file or its credentials.

## Deployment and troubleshooting

The `/download` route is registered when the Flask application starts. After
publishing an APK or changing the page, restart only the `MediaServer` service
to reload the Waitress process:

```powershell
cmd /c scripts\restart_service.bat
powershell -ExecutionPolicy Bypass -File .\scripts\service_status.ps1
```

Cloudflared does not need to be restarted for an application-only change.

Verify both the page and artifact endpoint after the restart:

```powershell
curl.exe -sS -o NUL -w "%{http_code}\n" https://media.anisparvez.in/download
curl.exe -sS -I "https://media.anisparvez.in/api/app/download?channel=production"
```

The page should return `200`, show the current production version, and the APK
endpoint should return `200` with content type
`application/vnd.android.package-archive`, `Content-Length`, and
`Accept-Ranges: bytes`.
