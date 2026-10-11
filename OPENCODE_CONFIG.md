# OpenCode Configuration Preservation Guide

**Repository:** `E:\MediaServer`  
**Captured:** 2026-10-06  
**OpenCode recorded version:** `2.0.11`  
**Node:** `v25.7.0`  
**npm:** `11.10.1`

This document records the OpenCode, Serena, MCP, plugin, SDK, and extension setup
needed to reinstall or repair the development environment. It intentionally contains
no API keys, passwords, OAuth tokens, or provider credentials.

## Important safety rules

- Do not reset or delete OpenCode state before making the backups in this document.
- Preserve unrelated working-tree changes in the repository.
- The live media database is `E:\MediaServer\media.db`; do not point an MCP server at it.
- The OpenCode background service has a secret in
  `%USERPROFILE%\.config\opencode\service.json`. Back it up securely, but never commit
  or paste its contents.
- Authentication/provider credentials are machine-local state. Re-authenticate through
  OpenCode's normal UI/CLI flow rather than copying secrets into tracked files.

## Project-scoped configuration

The committed source of truth is:

- `E:\MediaServer\opencode.json`
- `E:\MediaServer\docs\AGENT_EXTENSIONS.md`
- `E:\MediaServer\pyrightconfig.json`
- `E:\MediaServer\skills-lock.json`
- `E:\MediaServer\.opencode\skills\media-server-verify\`
- `E:\MediaServer\.agents\skills\` (third-party skills)

Current `opencode.json` contains:

### LSP

- `pyright` via `pyright --stdio`, Python extensions `.py` and `.pyi`.
- `dart` via `dart language-server --protocol=lsp`, Dart extension `.dart`.
- Pyright uses basic checking, automatic search paths, library type information, and
  workspace diagnostics.
- Dart is configured with Flutter enabled and closing notifications.

### MCP servers

- **Context7:** remote `https://mcp.context7.com/mcp`.
- **Mobile:** local `npx -y @mobilenext/mobile-mcp@latest`.
- **Media DB:** local read-only `uvx fastmcp-sqlite`, using
  `.opencode/db/media.snapshot.db`, restricted to `.opencode/db`, max 200 rows.
- **Serena:** local `uvx --from git+https://github.com/oraios/serena serena
  start-mcp-server --context desktop-app --project E:/MediaServer --tool-timeout 240`.
- Project MCP startup timeout: 120 seconds.

### Instructions and plugins

- Instruction URL:
  `https://raw.githubusercontent.com/JRedeker/opencode-shell-strategy/trunk/shell_strategy.md`
- Plugin: `@tarquinen/opencode-dcp`.

The two previous red plugin states had different causes:

| Previous entry | Correct replacement |
| --- | --- |
| `opencode-dynamic-context-pruning` | npm package `@tarquinen/opencode-dcp` in `plugins[]` |
| `opencode-shell-strategy` | Markdown instruction URL in `instructions[]`; it is not an npm package |

Do not put the shell-strategy repository name in `plugins[]`.

### Permissions and watcher safeguards

- Deny reads and edits of `E:/MediaServer/media.db`.
- Ask before reading `D:/Flicks/**`.
- Ask before `nssm`, `cloudflared`, `adb`, or `taskkill` shell commands.
- Allow web fetches.
- Ignore cache, virtual-environment, Flutter build, logs, updates, and media database
  files listed in `opencode.json`.

## Global OpenCode configuration

Current files under `%USERPROFILE%\.config\opencode\`:

- `opencode.json`: web search provider `parallel`; global MCP startup timeout 90 seconds;
  global `chrome-devtools` MCP using `npx -y chrome-devtools-mcp@latest`.
- `dcp.jsonc`: DCP schema reference only; no custom overrides currently recorded.
- `service.json`: private service configuration containing a secret. **Do not track or
  reproduce its contents in this guide.**

The current global JSON does not contain a Free Zen provider block or API key. The
observed failure was logged by the background server as `Invalid API key`, so the likely
state to preserve/check is the machine-local provider authentication/session state, not
the project `opencode.json`.

OpenCode's persistent service/database locations are normally:

- `%USERPROFILE%\.local\state\opencode\service.json`
- `%USERPROFILE%\.local\share\opencode\opencode.db`
- `%USERPROFILE%\.local\share\opencode\log\opencode.log`

The current log contains the Free Zen failure and should be inspected with secrets
redacted. Do not share raw logs because they may contain authorization headers, prompts,
or other sensitive data.

## Serena configuration

### Global Serena

File: `%USERPROFILE%\.serena\serena_config.yml`

Verified settings:

- `web_dashboard: true`
- `web_dashboard_open_on_launch: true`
- Dashboard listens on `127.0.0.1`; trusted hosts include `127.0.0.1` and `localhost`.
- `trusted_project_path_patterns` contains `E:/MediaServer`.
- Default maximum tool answer size is `150000` characters.

The dashboard is provided by Serena itself, normally at:

```text
http://127.0.0.1:24282/dashboard/index.html
```

The port increments if already occupied.

### Project Serena

File: `E:\MediaServer\.serena\project.yml`

This directory is gitignored and therefore machine-local. Current settings:

- Language servers: `dart`, `python`, `typescript`.
- HTML is intentionally omitted because Jinja templates produce diagnostic noise.
- Dart SDK pin: `3.13.5`.
- Initial prompt embeds the four memories:
  `architecture`, `testing-protocol`, `hls-invariants`, and `paths-and-drives`.

The four memory files live in:

```text
E:\MediaServer\.serena\memories\
```

`AGENTS.md` remains authoritative if a memory and the code/documentation disagree.
Serena must be restarted after changing language-server settings or the project YAML.

### Python diagnostics

`pyrightconfig.json` points Pyright at the repository virtual environment:

```json
{
  "venvPath": ".",
  "venv": "venv"
}
```

This prevents false unresolved-import errors for Flask, pytest, psutil, and other
installed packages. The repository has a documented pre-existing diagnostic baseline;
do not treat that baseline as a configuration failure.

## Skills and extensions

Tracked skill lock entries currently include:

- `chrome-extensions` from `GoogleChrome/modern-web-guidance`.
- `modern-web-guidance` from `GoogleChrome/modern-web-guidance`.

Additional project/runtime skills documented in `docs/AGENT_EXTENSIONS.md` include:

- `cloudflare`
- `webapp-testing`
- `media-server-verify`

The extension inventory and verification commands are maintained in
`docs/AGENT_EXTENSIONS.md`; update that file rather than duplicating package details
here when an extension changes.

## SDK and device environment

Recorded environment state:

- Python `3.14.3`, virtual environment `E:\MediaServer\venv`.
- Flutter `3.47.6` stable at `D:\src\flutter`.
- Dart `3.13.5`, bundled with Flutter.
- Android SDK root `D:\platform-tools-latest-windows`.
- Android platform-tools `37.0.1`; emulator `37.2.12`.
- FFmpeg `9.0.1` essentials build with AMF and D3D11va.

`D:\platform-tools-latest-windows` is a complete Android SDK, not only platform-tools.
There are six `adb.exe` copies on the machine; two are on `PATH`:

1. SDK adb, `37.0.1`, used by Flutter and first on `PATH`.
2. scrcpy-bundled adb, `37.0.0`, second on `PATH`.

Use one consistent adb client when working with a device. The Flutter Windows SDK has
a local patch in `packages/flutter_tools/lib/src/windows/visual_studio.dart`; the
recoverable diff is committed at:

```text
E:\MediaServer\docs\flutter-winsdk-location-patch.diff
```

Do not run `flutter upgrade --force` without backing up and restoring that patch. The
recovery sequence is documented in `docs/DEVELOPMENT_STATUS.md`.

## Storage and database safety

| Purpose | Location |
| --- | --- |
| Application, database, active HLS and previews | `E:\MediaServer` |
| Raw media | `D:\Flicks` |
| Upload staging | `D:\Flicks\.uploads` |
| Archive | `D:\Flicks\.archive` |
| Deleted-source staging | `D:\Flicks\.deleted` |

The media MCP uses the read-only snapshot:

```text
E:\MediaServer\.opencode\db\media.snapshot.db
```

Refresh it with:

```powershell
powershell -ExecutionPolicy Bypass -File .opencode\db\refresh-snapshot.ps1
```

Never substitute `E:\MediaServer\media.db` for the snapshot.

## Safe backup before reset or reinstall

Run in PowerShell, while OpenCode is stopped if possible:

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $env:USERPROFILE "OpenCode-backup-$stamp"
New-Item -ItemType Directory -Path $dest | Out-Null

Copy-Item "$env:USERPROFILE\.config\opencode" "$dest\config" -Recurse
Copy-Item "$env:USERPROFILE\.serena" "$dest\serena" -Recurse
Copy-Item "$env:USERPROFILE\.local\state\opencode" "$dest\state" -Recurse -ErrorAction SilentlyContinue
Copy-Item "$env:USERPROFILE\.local\share\opencode\opencode.db" "$dest\opencode.db" -ErrorAction SilentlyContinue
Copy-Item "$env:USERPROFILE\.local\share\opencode\log\opencode.log" "$dest\opencode.log" -ErrorAction SilentlyContinue
Copy-Item "E:\MediaServer\opencode.json" "$dest\project-opencode.json"
Copy-Item "E:\MediaServer\docs\AGENT_EXTENSIONS.md" "$dest\AGENT_EXTENSIONS.md"
Copy-Item "E:\MediaServer\pyrightconfig.json" "$dest\pyrightconfig.json"
Copy-Item "E:\MediaServer\skills-lock.json" "$dest\skills-lock.json"
```

Protect the backup directory because it includes private service/auth state. Do not
commit it or place it inside the repository.

## Restore checklist

1. Restore the project checkout and verify `git status`; do not overwrite unrelated
   working-tree changes.
2. Restore project files from Git: `opencode.json`, `docs/AGENT_EXTENSIONS.md`,
   `pyrightconfig.json`, skills, and the media-server verification skill.
3. Restore `%USERPROFILE%\.config\opencode\` and `%USERPROFILE%\.serena\` from a
   protected backup, or recreate them from the settings above.
4. Re-authenticate provider accounts through OpenCode's supported authentication flow;
   never put API keys in this repository.
5. Restart the OpenCode service, then check:

   ```powershell
   opencode service status
   opencode api get /api/info
   opencode mcp list
   ```

6. Confirm the Serena dashboard, MCP servers, plugin load state, and model list.
7. For the Free Zen issue, inspect the redacted log for `Invalid API key`, remove or
   refresh only the affected provider credential, and test that model before changing
   unrelated configuration.
8. Run project verification only with the repository rules in `AGENTS.md`; in
   particular, use `scripts\run_flutter_tests.ps1`, not bare `flutter test`.

## Historical verification

The preceding setup work recorded these results, but they are historical rather than a
fresh run for this document:

- Python suite: `362 passed, 1 skipped`.
- Flutter suite: `274 passed, 12 skipped`.
- Server root request: `GET / -> 200`.
- HLS state and movie-row counts were checked unchanged.

For the current repository's exact operational status, consult `docs/PROJECT_STATUS.md`
and run the required verification commands after restoration.
