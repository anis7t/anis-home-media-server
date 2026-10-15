# Moves NSSM hosting from E: (removable USB) to C: (system drive).
# Run elevated. Idempotent: safe to re-run.
# Steps: stop services, copy nssm.exe, repoint binPath, restart, verify.

$ErrorActionPreference = "Stop"
$Log = "C:\MediaServerLogs\nssm_move.log"
function L([string]$m) {
    $l = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    Write-Output $l; Add-Content -Path $Log -Value $l -ErrorAction SilentlyContinue
}

$src = "E:\MediaServer\bin\nssm.exe"
$dstDir = "C:\MediaServer\bin"
$dst = "$dstDir\nssm.exe"

L "stopping services..."
Stop-Service MediaServer, MediaServerRust -Force -ErrorAction SilentlyContinue
Start-Sleep 2

if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
Copy-Item $src $dst -Force
$h1 = (Get-FileHash $src -Algorithm SHA256).Hash
$h2 = (Get-FileHash $dst -Algorithm SHA256).Hash
if ($h1 -ne $h2) { throw "hash mismatch after copy" }
L "copied nssm.exe sha256=$($h1.Substring(0,16))..."

foreach ($s in @("MediaServer", "MediaServerRust")) {
    & sc.exe config $s binPath= "`"$dst`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc config failed for $s" }
    $pn = (Get-CimInstance Win32_Service -Filter "Name='$s'").PathName
    L "$s binPath now: $pn"
    if ($pn -ne $dst) { throw "repoint verification failed for $s" }
}

L "starting services..."
Start-Service MediaServerRust
Start-Service MediaServer
Start-Sleep 6
foreach ($s in @("MediaServer", "MediaServerRust")) {
    L "$s status: $((Get-Service $s).Status)"
}
L "MOVE DONE"
