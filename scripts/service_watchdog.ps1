# Media Server watchdog - keeps Rust and PostgreSQL alive across
# USB-volume (E:) dropouts. Idempotent: a healthy system is a logged no-op.
# Runs every 5 min from the MediaServerWatchdog scheduled task
# (principal awais\anis7, highest privileges). Safe to run by hand.
#
# Exit 0 always on a completed check; nonzero only on script-level failure.

param([switch]$DryRun)

$ErrorActionPreference = "Continue"
$LogDir = "C:\MediaServerLogs"
$LogFile = Join-Path $LogDir "watchdog.log"
$NssmProbe = "E:\MediaServer\bin\nssm.exe"
$PgCtl = "C:\postgres\pgsql\bin\pg_ctl.exe"
if (-not (Test-Path $PgCtl)) { $PgCtl = "E:\postgres\pgsql\bin\pg_ctl.exe" }
$PgData = "E:\pgdata"

function Write-WatchdogLog([string]$msg) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

# 1. E: must be present - every managed binary lives on it.
if (-not (Test-Path $NssmProbe)) {
    Write-WatchdogLog "SKIP E: volume absent ($NssmProbe missing); services left alone"
    exit 0
}

if ($DryRun) { Write-WatchdogLog "DRYRUN mode - no changes will be made" }

# 2. PostgreSQL first - Rust depends on it.
# Liveness is a TCP connect, NOT `pg_ctl status`: the probe is run by the
# logged-on admin account while the postmaster runs as NetworkService, so
# pg_ctl cannot open the process and reports "no server running" against a
# healthy cluster. The stale postmaster.pid left by the C: move is the
# same symptom. 5432 accepting a connection is the authoritative check.
function Test-PgUp() {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect("127.0.0.1", 5432, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) { $c.Close(); return $false }
        $c.EndConnect($iar)
        $c.Close()
        return $true
    } catch { return $false }
}
function Wait-PgUp() {
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Seconds 5
        if (Test-PgUp) { return $true }
    }
    return $false
}

if (Test-PgUp) {
    Write-WatchdogLog "OK postgres already running (5432 open)"
} else {
    $pgSvc = Get-Service -Name "MediaServerPG" -ErrorAction SilentlyContinue
    if ($pgSvc) {
        Write-WatchdogLog "START service MediaServerPG (was $($pgSvc.Status))"
        if (-not $DryRun) {
            try {
                Start-Service -Name "MediaServerPG" -ErrorAction Stop
                if (Wait-PgUp) { Write-WatchdogLog "OK postgres started (service)" }
                else { Write-WatchdogLog "FAIL postgres did not start; see $PgData\pg.log" }
            } catch {
                Write-WatchdogLog "FAIL MediaServerPG failed to start: $($_.Exception.Message)"
            }
        }
    } else {
        Write-WatchdogLog "START postgres via pg_ctl ($PgData)"
        if (-not $DryRun) {
            & $PgCtl -D $PgData -l "$PgData\pg.log" start > $null 2>&1
            if (Wait-PgUp) { Write-WatchdogLog "OK postgres started (pg_ctl)" }
            else { Write-WatchdogLog "FAIL postgres did not start; see $PgData\pg.log" }
        }
    }
}

# 3. NSSM services. MediaServerRust after PG so its pool connects on first try.
# Legacy Flask (MediaServer) is retired and deliberately excluded.
foreach ($svc in @("MediaServerRust")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) {
        Write-WatchdogLog "MISS service not installed: $svc"
        continue
    }
    if ($s.Status -eq "Running") {
        Write-WatchdogLog "OK $svc already running"
    } else {
        Write-WatchdogLog "START service $svc (was $($s.Status))"
        if (-not $DryRun) {
            try {
                Start-Service -Name $svc -ErrorAction Stop
                Start-Sleep -Seconds 3
                $now = (Get-Service -Name $svc).Status
                Write-WatchdogLog "OK $svc now $now"
            } catch {
                Write-WatchdogLog "FAIL $svc failed to start: $($_.Exception.Message)"
            }
        }
    }
}

Write-WatchdogLog "DONE check complete"
exit 0
