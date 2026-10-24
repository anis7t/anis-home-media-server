<#
.SYNOPSIS
    Configures Windows Display Driver Timeout Detection & Recovery (TDR) parameters.

.DESCRIPTION
    Increases TDR timeout thresholds in HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers:
    - TdrDelay: 8 (seconds before OS declares the GPU unresponsive, default is 2).
    - TdrDdiDelay: 20 (seconds before OS declares device driver interface hung, default is 5).
    
    This provides adequate headroom for intensive multi-GPU AMF 4K HDR chunk transcoding
    and prevents spurious Windows kernel GPU resets (TDR 0x00000117 / 0x00000141).

.EXAMPLE
    .\scripts\configure_tdr_registry.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "      Windows Graphics TDR Configuration Tool       " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"

if (-not (Test-Path $regPath)) {
    Write-Host "ERROR: Registry path $regPath does not exist." -ForegroundColor Red
    exit 1
}

Write-Host "Configuring TDR values in $regPath..." -ForegroundColor DarkGray

# 1. Set TdrDelay = 8 (Seconds)
Set-ItemProperty -Path $regPath -Name "TdrDelay" -Value 8 -Type DWord -Force
Write-Host "  [+] Set TdrDelay = 8 (Timeout increased from 2s -> 8s)" -ForegroundColor Green

# 2. Set TdrDdiDelay = 20 (Seconds)
Set-ItemProperty -Path $regPath -Name "TdrDdiDelay" -Value 20 -Type DWord -Force
Write-Host "  [+] Set TdrDdiDelay = 20 (DDI timeout increased from 5s -> 20s)" -ForegroundColor Green

# 3. Verify
$props = Get-ItemProperty -Path $regPath
if ($props.TdrDelay -eq 8 -and $props.TdrDdiDelay -eq 20) {
    Write-Host ""
    Write-Host "SUCCESS: Windows GraphicsDrivers TDR settings verified!" -ForegroundColor Green
    Write-Host "  TdrDelay:    $($props.TdrDelay) seconds" -ForegroundColor Green
    Write-Host "  TdrDdiDelay: $($props.TdrDdiDelay) seconds" -ForegroundColor Green
    Write-Host "  Status:      Active for all subsequent DirectX device contexts" -ForegroundColor DarkGray
} else {
    Write-Host "ERROR: Verification failed to confirm TDR properties." -ForegroundColor Red
    exit 1
}
