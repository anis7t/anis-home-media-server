# Rollback script to restore the single-GPU transcode production binary
Write-Host "[Rollback] Stopping MediaServerRust service..." -ForegroundColor Yellow
Stop-Service -Name "MediaServerRust" -Force -ErrorAction SilentlyContinue

$backup = "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe.bak-single-gpu"
$target = "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe"

if (Test-Path $backup) {
    Write-Host "[Rollback] Restoring backup binary from $backup..." -ForegroundColor Green
    Copy-Item $backup $target -Force
} else {
    Write-Host "[Rollback] Error: Backup binary $backup not found!" -ForegroundColor Red
    exit 1
}

Write-Host "[Rollback] Starting MediaServerRust service..." -ForegroundColor Yellow
Start-Service -Name "MediaServerRust"
Start-Sleep -Seconds 3

$svc = Get-Service -Name "MediaServerRust"
Write-Host "[Rollback] MediaServerRust status: $($svc.Status)" -ForegroundColor Cyan
