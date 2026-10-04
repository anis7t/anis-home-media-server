# Refresh the read-only SQLite snapshot used by the `media-db` MCP server.
#
# WHY THIS EXISTS
#   The `media-db` MCP server (mcp-server-sqlite) exposes a `write_query` tool that
#   runs INSERT/UPDATE/DELETE and commits. Pointing it at the live
#   E:\MediaServer\media.db would let an agent mutate production data while the
#   Waitress service (running as LocalSystem) is using it.
#
#   So the MCP points at .opencode/db/media.snapshot.db instead, which carries the
#   Windows read-only attribute. SQLite can read it and returns
#   "attempt to write a readonly database" for any write - an OS-level guarantee,
#   not a prompt-level one.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .opencode\db\refresh-snapshot.ps1
#
# The snapshot is gitignored. Run this before a session that needs current data.

$ErrorActionPreference = 'Stop'

$repo    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$source  = Join-Path $repo 'media.db'
$destDir = Join-Path $repo '.opencode\db'
$dest    = Join-Path $destDir 'media.snapshot.db'

if (-not (Test-Path $source)) {
    Write-Error "Source database not found: $source"
    exit 1
}

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

# Clear the read-only attribute before overwriting, then restore it.
if (Test-Path $dest) {
    attrib -R $dest
    Remove-Item $dest -Force
}

# Copy via a temp name so a concurrent reader never sees a half-written file.
$tmp = "$dest.tmp"
if (Test-Path $tmp) { Remove-Item $tmp -Force }
Copy-Item $source $tmp -Force

# Re-apply the read-only attribute BEFORE the final rename so the file is never
# observable in a writable state at its real path.
attrib +R $tmp
Move-Item $tmp $dest -Force

$size = (Get-Item $dest).Length
$rows = & (Join-Path $repo 'venv\Scripts\python.exe') -c @"
import sqlite3
c = sqlite3.connect(r'$dest')
print(c.execute('select count(*) from movies').fetchone()[0])
"@

Write-Host "Snapshot refreshed: $dest"
Write-Host ("  size : {0:N0} bytes" -f $size)
Write-Host "  movies rows: $rows"
Write-Host "  attribute  : read-only (writes are rejected by SQLite)"