# Moves PostgreSQL binaries E: -> C: and registers PG as a Windows service.
# Data stays on E:\pgdata. Service runs as NetworkService (postmaster
# refuses admin/LocalSystem). Run elevated. Idempotent: safe to re-run.

$ErrorActionPreference = "Stop"
$Log = "C:\MediaServerLogs\pg_move.log"
function L([string]$m) {
    $l = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    Write-Output $l; Add-Content -Path $Log -Value $l -ErrorAction SilentlyContinue
}

$OldBin = "E:\postgres\pgsql\bin\pg_ctl.exe"
$NewBinDir = "C:\postgres\pgsql\bin"
$NewCtl = "$NewBinDir\pg_ctl.exe"
$Data = "E:\pgdata"
$Svc = "MediaServerPG"

L "stopping postgres cleanly..."
& $OldBin -D $Data stop -m fast 2>&1 | ForEach-Object { L "pg_ctl: $_" }
Start-Sleep 3

L "copying binaries E:\postgres -> C:\postgres (this takes a few minutes)..."
if (-not (Test-Path "C:\postgres")) { New-Item -ItemType Directory -Path "C:\postgres" -Force | Out-Null }
$rc = Start-Process robocopy.exe -ArgumentList '"E:\postgres" "C:\postgres" /MIR /NFL /NDL /NJH /R:3 /W:5' -Wait -PassThru -NoNewWindow
L "robocopy exit=$($rc.ExitCode) (0-7 = success)"
if ($rc.ExitCode -gt 7) { throw "robocopy failed" }
if (-not (Test-Path $NewCtl)) { throw "pg_ctl missing after copy" }

L "setting ACLs for NetworkService..."
& icacls.exe $Data /grant "NT AUTHORITY\NetworkService:(OI)(CI)F" /T /Q 2>&1 | Select-Object -Last 1 | ForEach-Object { L "icacls data: $_" }
& icacls.exe "C:\postgres" /grant "NT AUTHORITY\NetworkService:(OI)(CI)RX" /T /Q 2>&1 | Select-Object -Last 1 | ForEach-Object { L "icacls bins: $_" }

$existing = Get-Service -Name $Svc -ErrorAction SilentlyContinue
if ($existing) {
    L "service exists - removing for clean re-register..."
    Stop-Service $Svc -Force -ErrorAction SilentlyContinue
    & $NewCtl unregister -N $Svc 2>&1 | ForEach-Object { L "unregister: $_" }
}
L "registering service $Svc..."
& $NewCtl register -N $Svc -U "NT AUTHORITY\NetworkService" -D $Data -S auto 2>&1 | ForEach-Object { L "register: $_" }
& sc.exe failure $Svc reset= 86400 actions= restart/60000/restart/60000/restart/120000 | Out-Null
L "recovery policy: restart x3 with backoff"

L "starting service..."
Start-Service $Svc
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep 5
    & $NewCtl status -D $Data > $null 2>&1
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}
$s = (Get-Service $Svc).Status
L "$Svc status: $s pg_ready=$ready"
if (-not $ready) { throw "postgres did not become ready" }
L "PG MOVE DONE"
