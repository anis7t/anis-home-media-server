<#
.SYNOPSIS
    Rotates the Admin PIN for Anis' Home Media Server in PostgreSQL.

.DESCRIPTION
    Safely updates the 'admin_pin' key in the 'settings' table of the 'media_server'
    PostgreSQL database. Validates that the new PIN consists of at least 4 digits.
    Supports verifying the current PIN, interactive secure prompts, and a -Force
    switch for break-glass recovery.

.PARAMETER NewPin
    The new Admin PIN to set (must be at least 4 digits). If omitted, an interactive
    secure prompt is shown.

.PARAMETER CurrentPin
    The existing Admin PIN. If provided and -Force is not set, the script verifies
    that this matches the currently configured PIN before updating.

.PARAMETER Force
    Bypasses verification of the current PIN (break-glass superuser recovery).

.PARAMETER Database
    PostgreSQL database name (default: media_server).

.PARAMETER User
    PostgreSQL user (default: postgres).

.PARAMETER DbHost
    PostgreSQL host (default: 127.0.0.1).

.PARAMETER Port
    PostgreSQL port (default: 5432).

.EXAMPLE
    .\scripts\rotate_admin_pin.ps1 -CurrentPin "791654" -NewPin "123456"

.EXAMPLE
    .\scripts\rotate_admin_pin.ps1 -Force -NewPin "123456"

.EXAMPLE
    .\scripts\rotate_admin_pin.ps1
#>

param(
    [string]$NewPin = "",
    [string]$CurrentPin = "",
    [switch]$Force,
    [string]$Database = "media_server",
    [string]$User = "postgres",
    [string]$DbHost = "127.0.0.1",
    [int]$Port = 5432
)

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "         Admin PIN Rotation Tool                    " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Locate psql.exe
$psqlCandidates = @(
    "C:\postgres\pgsql\bin\psql.exe",
    "E:\postgres\pgsql\bin\psql.exe",
    "C:\Program Files\PostgreSQL\18\bin\psql.exe",
    "C:\Program Files\PostgreSQL\17\bin\psql.exe",
    "C:\Program Files\PostgreSQL\16\bin\psql.exe"
)

$psql = $null
foreach ($c in $psqlCandidates) {
    if (Test-Path $c) {
        $psql = $c
        break
    }
}

if (-not $psql) {
    $cmd = Get-Command "psql.exe" -ErrorAction SilentlyContinue
    if ($cmd) { $psql = $cmd.Source }
}

if (-not $psql) {
    Write-Host "ERROR: psql.exe was not found in standard paths." -ForegroundColor Red
    exit 1
}

Write-Host "Using psql: $psql" -ForegroundColor DarkGray

$env:PGPASSWORD = if ($env:PGPASSWORD) { $env:PGPASSWORD } else { "postgres" }

# Helper to execute SQL via psql and return trimmed output
function Invoke-PsqlQuery([string]$query) {
    $out = & $psql -h $DbHost -p $Port -U $User -d $Database -t -A -c $query 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Database query failed: $out" -ForegroundColor Red
        exit 1
    }
    return ($out | Out-String).Trim()
}

# 2. Fetch current stored PIN
Write-Host "Checking current admin PIN configuration..." -ForegroundColor DarkGray
$storedPin = Invoke-PsqlQuery "SELECT value FROM settings WHERE key = 'admin_pin';"

if (-not [string]::IsNullOrWhiteSpace($storedPin)) {
    Write-Host "An admin PIN is currently configured in the database." -ForegroundColor Yellow
} else {
    Write-Host "No admin PIN is currently configured (empty or unset)." -ForegroundColor Yellow
}

# 3. Verify Current PIN unless -Force is specified
if (-not [string]::IsNullOrWhiteSpace($storedPin) -and -not $Force) {
    if ([string]::IsNullOrWhiteSpace($CurrentPin)) {
        $secCurrent = Read-Host "Enter CURRENT Admin PIN" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secCurrent)
        $CurrentPin = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    if ($CurrentPin.Trim() -ne $storedPin.Trim()) {
        Write-Host "ERROR: Verification failed. The provided Current PIN does not match the configured PIN." -ForegroundColor Red
        Write-Host "Tip: Use -Force from an elevated host console if you need break-glass recovery." -ForegroundColor DarkGray
        exit 1
    }
    Write-Host "Current PIN verified successfully." -ForegroundColor Green
} elseif ($Force) {
    Write-Host "Bypassing current PIN verification (-Force active)." -ForegroundColor Yellow
}

# 4. Prompt for New PIN if not provided
if ([string]::IsNullOrWhiteSpace($NewPin)) {
    $secNew1 = Read-Host "Enter NEW Admin PIN (minimum 4 digits)" -AsSecureString
    $BSTR1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secNew1)
    $cleanNew1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR1)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR1)

    $secNew2 = Read-Host "Confirm NEW Admin PIN" -AsSecureString
    $BSTR2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secNew2)
    $cleanNew2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR2)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR2)

    if ($cleanNew1 -ne $cleanNew2) {
        Write-Host "ERROR: New PIN entries do not match." -ForegroundColor Red
        exit 1
    }
    $NewPin = $cleanNew1
}

$NewPinClean = $NewPin.Trim()

# 5. Validate New PIN format
if ($NewPinClean.Length -lt 4) {
    Write-Host "ERROR: New PIN must be at least 4 characters long (got $($NewPinClean.Length))." -ForegroundColor Red
    exit 1
}

if ($NewPinClean -notmatch '^\d+$') {
    Write-Host "ERROR: New PIN must contain numeric digits only." -ForegroundColor Red
    exit 1
}

# 6. Apply PIN update to PostgreSQL
Write-Host "Updating Admin PIN in database..." -ForegroundColor Cyan

# Escape single quotes just in case (though digits regex ensures no quotes)
$escapedPin = $NewPinClean.Replace("'", "''")
$updateSql = @"
INSERT INTO settings (key, value)
VALUES ('admin_pin', '$escapedPin')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
"@

Invoke-PsqlQuery $updateSql | Out-Null

# 7. Verify updated value
$verifyPin = Invoke-PsqlQuery "SELECT value FROM settings WHERE key = 'admin_pin';"
if ($verifyPin -ne $NewPinClean) {
    Write-Host "ERROR: Verification query failed to match updated PIN." -ForegroundColor Red
    exit 1
}

$maskedPin = "*" * $NewPinClean.Length
Write-Host "SUCCESS: Admin PIN has been rotated successfully!" -ForegroundColor Green
Write-Host "Configured PIN: $maskedPin ($($NewPinClean.Length) digits)" -ForegroundColor Green
Write-Host "Old PIN is now invalidated across all administrative endpoints." -ForegroundColor DarkGray
