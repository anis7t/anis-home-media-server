# RETIRED (2026-10-24) — Issue 12
# The `media-db` MCP server and SQLite snapshot are fully decommissioned.
# PostgreSQL 18.4 (MediaServerPG on port 5432, database `media_server`) is the
# authoritative database, queried via `postgresql-mcp` or psql.

Write-Warning "refresh-snapshot.ps1 is RETIRED. PostgreSQL 18.4 (MediaServerPG) is the system of record."
exit 0