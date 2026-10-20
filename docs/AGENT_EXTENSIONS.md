# Agent extensions for this repository

This file records the OpenCode extensions configured for Anis' Media Server:
what is installed, why, and how to verify or change it. Everything lives in
`opencode.json` at the repository root (project-scoped, committed, so it is
reviewable by a verification model).

## Status

| Extension | Kind | State |
| --- | --- | --- |
| `pyright` | LSP | installed globally via npm (`pyright@1.1.414`) |
| `dart` | LSP | provided by the Flutter SDK already on `PATH` |
| `rust-analyzer` | LSP | installed globally via rustup (`rustc`/`cargo` 1.99.0, host `x86_64-pc-windows-msvc`) |
| `typescript` | LSP | installed globally via npm (`typescript-language-server@6.0.2`, `typescript@7.0.2`) |
| `context7` | MCP (remote) | connected |
| `mobile` | MCP (local, `npx @mobilenext/mobile-mcp`) | connected, 33 tools, no device attached |
| `media-db` | MCP (local, `uvx fastmcp-sqlite`) | connected, read-only |
| `postgres` | MCP (local, `uvx postgresql-mcp`) | connected, 15 tools; targets the portable dev cluster (see below) |
| `serena` | MCP (local, `uvx` + git) | connected, 3 language servers, dashboard on :24282 |
| `chrome-devtools` | MCP | pre-existing, global config |
| `cloudflare` | skill | `.agents/skills/cloudflare` |
| `webapp-testing` | skill | `.agents/skills/webapp-testing` |
| `media-server-verify` | skill | `.opencode/skills/media-server-verify` (authored here) |
| `shell_strategy.md` | instruction | loaded from the JRedeker repo (remote URL) |
| `@tarquinen/opencode-dcp` | plugin | configured |

Note: LSP is **disabled by default** in OpenCode, so the `lsp` block in
`opencode.json` is what turns diagnostics on. Without it there is no type
feedback at all.

## Verify

```powershell
opencode mcp list
```

LSP servers start lazily, when a file of a matching extension is opened. There is
no status command for them; the cheapest direct check is running the analyzer:

```powershell
.\venv\Scripts\python.exe -m pytest tests/     # Python
cd flutter_client; dart analyze lib test       # Dart/Flutter
```

## Rust, React and PostgreSQL dev stack (added 2026-10-10)

### Rust

Installed with `rustup-init.exe -y --profile default --stable` into
`%USERPROFILE%\.cargo` (user-scoped, **no administrator rights required**).
`%USERPROFILE%\.cargo\bin` was appended to the **user** `PATH`.

| Item | Version |
| --- | --- |
| `rustc` / `cargo` | 1.99.0 (`stable-x86_64-pc-windows-msvc`) |
| `rustup` | 1.29.1 |
| components | `clippy`, `rustfmt`, `rust-analyzer`, `rust-docs`, `rust-std` |

**KNOWN BLOCKER - Rust cannot link yet.** Two separate faults, both verified:

1. **Windows SDK is absent.** The VS C++ Build Tools are present
   (`C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools`, MSVC
   `14.50.35717`) but `C:\Program Files (x86)\Windows Kits\10` contains only
   `Catalogs`, `Redist` and `UnionMetadata` - there is **no `Lib` and no
   `Include`**, so `kernel32.lib` does not exist anywhere on the machine.
   `vswhere` still *reports* `Microsoft.VisualStudio.Component.Windows11SDK.26100`
   as installed; **that answer is a false positive** - trust the directory, not
   `vswhere`. Linking fails with `LNK1181: cannot open input file 'kernel32.lib'`.
2. **`link.exe` is shadowed on `PATH`.** `C:\msys64\usr\bin` is on the user
   `PATH`, and MSYS2's GNU coreutils `link` (a hard-link utility, not a linker)
   wins name resolution. rustc invokes it and gets
   `link: extra operand '<file>.rcgu.o'`.

Fix 1 requires elevation and must be run by the user:

```powershell
winget install --id Microsoft.WindowsSDK.10.0.26100 --source winget
```

Fix 2 is applied by pointing cargo at the real MSVC linker. Add to
`%USERPROFILE%\.cargo\config.toml` (create it if absent):

```toml
[target.x86_64-pc-windows-msvc]
linker = "C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\VC\\Tools\\MSVC\\14.50.35717\\bin\\Hostx64\\x64\\link.exe"
```

That path embeds the MSVC version and must be updated when the Build Tools are
upgraded. Until **both** fixes land, `cargo build` fails. Editing, rustfmt,
clippy and the `rust-analyzer` LSP all work regardless - only linking is broken.

### React / TypeScript

Installed **globally** via npm (shims land in `%APPDATA%\npm`):

| Package | Version |
| --- | --- |
| `typescript-language-server` | 6.0.2 |
| `typescript` | 7.0.2 |
| `prettier` | 3.9.9 |

> **Windows spawn gotcha:** npm creates `foo`, `foo.cmd` and `foo.ps1`. A bare
> `typescript-language-server` resolves **only** through `cmd /c`; a direct
> `spawn()` (what an LSP client does) returns `ENOENT`. The `typescript` LSP entry
> in `opencode.json` therefore names **`typescript-language-server.cmd`**
> explicitly. Do not "simplify" it back to the extension-less name.

VS Code extensions installed: `rust-lang.rust-analyzer` (note: the publisher is
`rust-lang`, **not** `rust-analyzer` - the latter ID does not exist),
`dbaeumer.vscode-eslint`, `esbenp.prettier-vscode`,
`bradlc.vscode-tailwindcss`. Recommendations are pinned in
`.vscode/extensions.json`.

### PostgreSQL (portable, no Windows service)

Installed as a **portable, user-scoped** cluster so that no administrator
rights and no service registration are involved.

| Item | Location |
| --- | --- |
| Server binaries | `E:\postgres\pgsql` (PostgreSQL **18.4**, EDB zip build) |
| Data cluster | `E:\pgdata` |
| Log | `E:\pgdata\pg.log` |
| Dev database | `media_dev` (role `postgres`, `scram-sha-256`) |
| Credentials | `C:\Users\anis7\.config\opencode\postgres-dev.env` (machine-local, **never commit**) |

`E:\postgres\pgsql\bin` was appended to the **user** `PATH`, so `psql`,
`pg_ctl`, `pg_isready` and `initdb` are on `PATH` in new shells.

Start and stop (always with `pg_ctl`; never run `postgres.exe` directly):

```powershell
& 'E:\postgres\pgsql\bin\pg_ctl.exe' -D E:\pgdata -l E:\pgdata\pg.log start
& 'E:\postgres\pgsql\bin\pg_ctl.exe' -D E:\pgdata status
& 'E:\postgres\pgsql\bin\pg_ctl.exe' -D E:\pgdata stop -m fast
```

**Gotcha - `pg_ctl start` blocks under this harness.** The postmaster inherits
the console handles, so the calling shell waits for the server and appears to
hang. Launch it detached:

```powershell
Start-Process -FilePath 'E:\postgres\pgsql\bin\pg_ctl.exe' `
  -ArgumentList @('-D','E:\pgdata','-l','E:\pgdata\pg.log','start') -WindowStyle Hidden -Wait
```

**Gotcha - slow `fsync` on `E:`.** Startup performs a data-directory sync that
measured **~33 s**, and an unclean stop forces a full recovery pass on the next
start. `pg_isready` can report "no response" for over a minute on a cold start.
Wait for `database system is ready to accept connections` in the log before
concluding it failed.

**Gotcha - `0xC0000142` false alarm.** An `autovacuum worker ... terminated by
exception 0xC0000142` (`STATUS_DLL_INIT_FAILED`) followed by
`terminating any other active server processes / reinitializing` appeared during
setup and looked like a recurring crash loop. It reproduced twice, then never
again once the server was started detached with the log preserved. The pattern
was tied to the harness killing the process tree mid-start, **not** to a real
defect in the cluster. If it appears in normal use, check
`Get-WinEvent -LogName Application` first - during setup it produced **no**
event-log entry, which is what distinguishes the harness artifact from a genuine
child-process fault.

### The `postgres` MCP server

`postgresql-mcp` **1.1.0** (published 2026-08-03) via `uvx`, consistent with the
existing `serena` / `fastmcp-sqlite` entries. It was chosen over the npm
`postgres-mcp` package, whose last release was 2025-04-20, and over
`@modelcontextprotocol/server-postgres`, which npm marks **deprecated**. It
supplies 15 tools (query execution, schema exploration, table analysis, `EXPLAIN`
plans), is read-only by default, and is SQL-injection aware.

Configuration lives in the **committed** `opencode.json`, so the password is
referenced by substitution and never written to the repository:

```jsonc
"POSTGRES_PASSWORD": "{env:POSTGRES_PASSWORD}"
```

`POSTGRES_PASSWORD` is set as a **user environment variable**. Consequences:

- `opencode.json` stays secret-free and reviewable.
- The OpenCode service inherits the variable only when it **starts after** the
  variable was defined. After changing it, restart the service (OpenCode UI ->
  restart, or `opencode service restart` in a separate terminal).
- Until that restart the server still connects but every query fails with
  `fe_sendauth: no password supplied`. That is the expected symptom of a stale
  service process, not of a bad password - verify the password independently with
  `psql` before suspecting the credential.

`ALLOW_WRITE_OPERATIONS` is set to `true` because `media_dev` is a disposable
local development database. Set it to `false` to make the server read-only.

## Plugins and instructions - repo names are not package names

Two entries in `opencode.json` were previously listed under `plugins[]` and failed
on every startup with `NpmInstallFailedError: 404`. Neither package has ever existed
on npm; the cause was using **GitHub repository names where npm package names** were
required, and putting one entry in the wrong array entirely.

| Was listed in `plugins[]` | Reality | Correct wiring |
| --- | --- | --- |
| `opencode-dynamic-context-pruning` | Real repo `Opencode-DCP/opencode-dynamic-context-pruning`; the npm name is **`@tarquinen/opencode-dcp`** | `plugins[]` |
| `opencode-shell-strategy` | Real repo `JRedeker/opencode-shell-strategy` (MIT), but it is **not an npm package** - it is a markdown instruction file | `instructions[]` |

**`opencode-shell-strategy` could never have worked in `plugins[]`.** npm has no such
package under any scope; it is installed as an instruction file instead:

```json
"instructions": [
  "https://raw.githubusercontent.com/JRedeker/opencode-shell-strategy/trunk/shell_strategy.md"
]
```

It teaches non-interactive shell forms (`npm init -y`, `git commit -m`, `sudo -n`,
`--no-pager`) because OpenCode's shell has no TTY/PTY, so anything that prompts hangs
until timeout.

`@tarquinen/opencode-dcp` prunes obsolete tool outputs to cut token use. It is
**AGPL-3.0-or-later**; that is fine here because it is a dev-time tool and is never
linked into the shipped application.

### Verify

A failed npm plugin is logged, not thrown, so the session still works - it just shows
as a red dot. Check the log rather than assuming:

```powershell
Select-String -Path "$env:USERPROFILE\.local\share\opencode\log\opencode.log" `
              -Pattern "failed to load plugin"
```

Package names are cheap to verify before committing them:

```powershell
npm view <package> version      # 404 means the name is wrong
```

`pyright` reports **9 pre-existing errors and 0 warnings** across
`app/config.py` + `app/services/transcode_service.py` + `app/services/gpu_service.py`,
all 9 in `transcode_service.py`: 5 `reportUndefinedVariable`, 3
`reportAttributeAccessIssue`, 1 `reportPossiblyUnboundVariable`. Both analyzers in
play agree exactly - npm `pyright@1.1.414` (the `lsp` block) and Serena's pinned
`1.1.403`.

These are the project's existing state, not regressions - do not treat a non-zero
count as something this setup introduced. Across `app/`, `scripts/` and the root
scripts the total is **66**.

`pyrightconfig.json` is what makes these numbers mean anything. Without it pyright
does not see `.\venv` and reports `Import "..." could not be resolved` as an **Error**
on every file that imports Flask, pytest or psutil - which is why `app/config.py` used
to appear in this list and now does not. Verify with:

```powershell
pyright --outputjson app/config.py       # 0 diagnostics
```

## Serena

Installed as an MCP server (`uvx --from git+https://github.com/oraios/serena serena
start-mcp-server --context desktop-app --project E:/MediaServer`), pinned in
`opencode.json`. It is a **second, independent** code-intelligence stack from the
`lsp` block above - it spawns its own Pyright, its own Dart SDK and its own
TypeScript server, and it does not read `opencode.json`'s LSP settings.

### The dashboard is not a separate install

There is no dashboard package on this machine. It is a Flask app served *by the MCP
server process itself*, enabled by `web_dashboard: true`:

```
http://127.0.0.1:24282/dashboard/index.html
```

The port increments if 24282 is taken (24283, 24284, ...). It can read and write both
config files, add/remove language servers, edit memories, show live tool-call stats and
logs, and shut the server down. **Prefer editing the files** - the changes are
reviewable diffs, and language servers only pick them up on restart anyway.

### Two config layers, and one that silently fails

| File | Scope |
| --- | --- |
| `%USERPROFILE%\.serena\serena_config.yml` | global |
| `.serena\project.yml` | this project |

`.serena/` is gitignored, so all of it is machine-local - consistent with the
hardcoded `--project E:/MediaServer` path in `opencode.json`.

**`trusted_project_path_patterns` gates `ls_specific_settings`.** It is set to
`["E:/MediaServer"]` (Serena's own default is `["**"]`). If a project is not trusted,
`serena/project.py` **discards** `ls_specific_settings` from `project.yml` and only
logs a warning - so a language-server pin looks configured and does nothing. Check the
startup log for `not trusted` before concluding a setting is wrong.

### Current configuration

- **Languages: `dart`, `python`, `typescript`.** `html` was removed - `templates/*.html`
  is Jinja2 and the HTML server reported 18 Errors + 5 Warnings of pure noise on
  `templates/library.html` alone (see *Deliberately omitted* below).
- **`typescript`** is kept despite there being no `.ts` files: it is the only server
  covering `static/js/`, and returns real symbols for e.g. `runChunkedUpload`.
- **Dart is pinned to `3.13.4`** via `ls_specific_settings.dart.dart_sdk_version`,
  matching `flutter_client/pubspec.yaml` (`sdk: ^3.13.4`) and the host Flutter SDK.
  Serena's default is **3.7.1**, which predates the language the client is written in.
- **`--tool-timeout 240`** (was 120, which is below Serena's own global default). At
  120 the startup log recorded `AddLanguage:python failed after 1 minutes, 58.6 seconds
  / Request timed out`.

### Memories

Four pointer memories in `.serena/memories/` - `architecture`, `testing-protocol`,
`hls-invariants`, `paths-and-drives` - plus an `initial_prompt` that inlines all four
via `embed_memory()`.

They are **deliberately pointers, not copies.** `.serena/` is gitignored, so duplicating
the invariants from `AGENTS.md` there would create an untracked file that silently
drifts from the authoritative text. Each memory routes to the right `AGENTS.md` section
and states that `AGENTS.md` wins on any conflict.

When editing `initial_prompt`, note that `embed_memory()` **swallows load failures and
returns an empty string** (`agent.py`, `log.error` then `return ""`) - a typo'd memory
name is indistinguishable from success. Read it back rather than trusting the YAML:

```powershell
# activate the project, then confirm the memory actually rendered:
Select-String -Path "$env:USERPROFILE\.serena\logs\<today>\*.txt" `
              -Pattern "Tried to embed memory"
```

No output means all four resolved. `list_memories` must return exactly the names used
in the `embed_memory()` calls.

### Restart is the gate

`language_servers`, `ls_specific_settings` and the Python venv fix all require a Serena
restart. `restart_language_server` is not in the active toolset, so start a fresh
session. Changing languages live from the dashboard works, but a config edit plus a
restart is the reviewable path.

## Why the database MCP is pointed at a snapshot

`E:\pgdata` — the PostgreSQL 18.4 data directory for the live `media_server`
database — is production data, written by a service running as `NetworkService`.
The obvious SQLite MCP server (`mcp-server-sqlite`, the one published by
modelcontextprotocol) exposes a `write_query` tool that runs
`INSERT`/`UPDATE`/`DELETE` and commits. Pointing it at the live database would
put an unguarded write path on production data.

Two independent guards are in place instead:

1. **The MCP server is read-only by default.** `fastmcp-sqlite` has
   `--read-only` as its default; writes require an explicit `--allow-write`,
   which is not passed. It is also confined with `--allowed-dir`.
2. **The database file itself is read-only.** The MCP targets
   `.opencode/db/media.snapshot.db`, a copy carrying the Windows read-only
   attribute. SQLite reads it normally and rejects any write with
   `attempt to write a readonly database`. This is enforced by the OS, not by
   instructions.

Refresh the snapshot before a session that needs current data:

```powershell
powershell -ExecutionPolicy Bypass -File .opencode\db\refresh-snapshot.ps1
```

The snapshot is gitignored. The refresh script sets the read-only attribute
before the atomic rename, so the file is never observable in a writable state at
its real path.

## Android device automation

Installed: **`@mobilenext/mobile-mcp`** (v1.0.8, Apache-2.0,
<https://github.com/mobile-next/mobile-mcp>). Exposes accessibility-tree
snapshots and coordinate taps for real devices, emulators and simulators. It is
the right tool for driving the Flutter client on the Fire TV Stick 4K and for
reproducing the D-pad focus-traversal issues in `AGENTS.md` by observation
rather than by inspection.

Configuration notes:

- **Package identity matters.** The unscoped `mobile-mcp` on npm is a *different,
  abandoned* project (v0.0.7, last published April 2025, repo `runablehq/mobile-mcp`).
  Use the scoped `@mobilenext/mobile-mcp`. Do not "simplify" the name.
- The binary is `mcp-server-mobile`; `--stdio` is the default transport.
- It drives whichever device `adb` reports, and there is no implicit "current
  device" - every call takes an explicit device id. With nothing connected,
  `mobile_list_available_devices` returns `{"devices": []}`, which matches
  `adb devices` and means the server is healthy but idle.
- It complements rather than replaces `adb`/scrcpy: `run_scrcpy.bat` remains the
  way to watch the device while the MCP acts on it.

### Safety

This MCP sends real taps, swipes and key events to a physical TV. The announce /
release protocol in `AGENTS.md` is a **strict invariant** and applies to MCP
driven input exactly as it does to manual `adb`:

1. Before any input that takes over the remote, state
   `"Please do not touch the remote..."`.
2. When finished, state `"The app is free from your control."`.

Because an agent can reach for these tools unprompted, keep the `shell` `adb *`
and `adb`-equivalent guards in `opencode.json` in place, and prefer
`screen_capture` / `snapshot` (read-only) over tap and key tools when
diagnosing.

## Deliberately omitted

- **`@modelcontextprotocol/server-filesystem`** - duplicates the built-in
  `read`/`write`/`glob`/`grep` tools.
- **`@modelcontextprotocol/server-sequential-thinking`** - the model already
  reasons stepwise; the tool mostly adds context cost.
- **`mcp-server-github`** - last published April 2025; the `gh` CLI is already
  installed and is what the `report` skill uses.
- **`@playwright/mcp`** - `chrome-devtools` and the built-in browser namespace
  already cover browser automation, and `webapp-testing` documents the
  Playwright path.
- **HTML/CSS LSP** - `templates/*.html` is Jinja2, so an HTML server reports
  syntax errors on every template expression. Noise without signal. This was
  independently re-added to Serena's language servers and removed again;
  symbol tools on `templates/` now correctly report "no suitable language
  server".
- **The unscoped `mobile-mcp` npm package** - not "the same tool, older". It is
  a different project (`runablehq/mobile-mcp`), abandoned since April 2025. The
  package here is the scoped `@mobilenext/mobile-mcp`. An earlier draft of this
  document judged `mobile-mcp` by version alone and reached the wrong conclusion
  about it being unmaintained; the real project is at v1.0.8.

## Install locations

- npm globals: `%APPDATA%\npm` (`pyright`, `chrome-devtools-mcp`, `@opencode/cli`)
- Python MCP servers: cached by `uvx` under
  `%LOCALAPPDATA%\uv\cache` - no install step, resolved on first launch
- Skills: `.agents/skills/` (third-party, `skills-lock.json` tracks them) and
  `.opencode/skills/` (project-authored)

`cloudflare` and `webapp-testing` were installed with shallow sparse git clones
rather than `npx skills add`, because the npm wrapper was repeatedly killed
mid-extraction by server restarts and left a half-written skill directory. They
are functionally identical, but they are **not** recorded in `skills-lock.json`;
if that file is ever used with `npx skills update`, expect those two to be
reported as unmanaged rather than to be silently updated.