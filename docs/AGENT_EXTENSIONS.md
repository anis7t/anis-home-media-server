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
| `context7` | MCP (remote) | connected |
| `mobile` | MCP (local, `npx @mobilenext/mobile-mcp`) | connected, 33 tools, no device attached |
| `media-db` | MCP (local, `uvx fastmcp-sqlite`) | connected, read-only |
| `serena` | MCP (local, `uvx` + git) | connected |
| `chrome-devtools` | MCP | pre-existing, global config |
| `cloudflare` | skill | `.agents/skills/cloudflare` |
| `webapp-testing` | skill | `.agents/skills/webapp-testing` |
| `media-server-verify` | skill | `.opencode/skills/media-server-verify` (authored here) |
| `opencode-shell-strategy` | plugin | configured |
| `opencode-dynamic-context-pruning` | plugin | configured |

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

`pyright` reports 11 pre-existing errors and 1 warning in
`app/config.py` + `app/services/transcode_service.py`, and 0 in
`app/services/gpu_service.py`. These are the project's existing state, not
regressions - do not treat a non-zero count as something this setup introduced.

## Why the database MCP is pointed at a snapshot

`E:\MediaServer\media.db` is production data, written by a service running as
`LocalSystem`. The obvious SQLite MCP server (`mcp-server-sqlite`, the one
published by modelcontextprotocol) exposes a `write_query` tool that runs
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
  syntax errors on every template expression. Noise without signal.
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