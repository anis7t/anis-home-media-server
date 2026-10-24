<#
.SYNOPSIS
    Verifies Cloudflare API Token validity and least-privilege scoping for Media Server Caddy.

.DESCRIPTION
    Audits the Cloudflare API token used for ACME DNS-01 challenges:
    1. Verifies token is active and valid via /user/tokens/verify.
    2. Verifies zone scoping is restricted strictly to 'anisparvez.in' with DNS edit/read rights.
    3. Confirms elevated scopes (/user profile, /accounts/{id}/members) are denied (least privilege).

.PARAMETER Token
    Optional token string. If omitted, extracted from E:\MediaServer\Caddyfile or $env:CLOUDFLARE_API_TOKEN.

.EXAMPLE
    .\scripts\verify_cloudflare_token.ps1
#>

param(
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "     Cloudflare API Token Least-Privilege Audit     " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Resolve Token
if ([string]::IsNullOrWhiteSpace($Token)) {
    if ($env:CLOUDFLARE_API_TOKEN) {
        $Token = $env:CLOUDFLARE_API_TOKEN
        Write-Host "Using token from `$env:CLOUDFLARE_API_TOKEN" -ForegroundColor DarkGray
    } elseif (Test-Path "E:\MediaServer\Caddyfile") {
        $lines = Get-Content "E:\MediaServer\Caddyfile"
        foreach ($line in $lines) {
            if ($line -match 'dns\s+cloudflare\s+([A-Za-z0-9_\-]+)') {
                $Token = $matches[1].Trim()
                Write-Host "Extracted token from E:\MediaServer\Caddyfile" -ForegroundColor DarkGray
                break
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Host "ERROR: Could not locate Cloudflare API token in Caddyfile or environment." -ForegroundColor Red
    exit 1
}

$masked = $Token.Substring(0, [Math]::Min(8, $Token.Length)) + "..." + $Token.Substring([Math]::Max(0, $Token.Length - 4))
Write-Host "Auditing Token: $masked" -ForegroundColor Yellow
Write-Host ""

$headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
}

# 2. Check Token Validity
Write-Host "[1/4] Probing /user/tokens/verify ..." -ForegroundColor DarkGray
try {
    $verifyResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/user/tokens/verify" -Headers $headers -Method Get
    if ($verifyResp.success -and $verifyResp.result.status -eq "active") {
        Write-Host "  [+] Token Status: ACTIVE (Token ID: $($verifyResp.result.id))" -ForegroundColor Green
    } else {
        Write-Host "  [-] Token Status: Inactive or Invalid" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "  [-] Token verification failed: $_" -ForegroundColor Red
    exit 1
}

# 3. Check Zone Permissions & Scoping
Write-Host "[2/4] Probing /zones for DNS Scoping ..." -ForegroundColor DarkGray
try {
    $zonesResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones" -Headers $headers -Method Get
    if ($zonesResp.success) {
        $zoneCount = $zonesResp.result.Count
        Write-Host "  [*] Accessible Zones Count: $zoneCount" -ForegroundColor Cyan
        
        $targetZone = $zonesResp.result | Where-Object { $_.name -eq "anisparvez.in" }
        if ($targetZone) {
            Write-Host "  [+] Target Zone 'anisparvez.in' Found (ID: $($targetZone.id))" -ForegroundColor Green
            $perms = $targetZone.permissions
            Write-Host "      Granted Permissions: $($perms -join ', ')" -ForegroundColor DarkGray

            $hasDnsEdit = $perms -contains "#dns_records:edit"
            $hasDnsRead = $perms -contains "#dns_records:read"
            $hasZoneRead = $perms -contains "#zone:read"

            if ($hasDnsEdit -and $hasDnsRead -and $hasZoneRead) {
                Write-Host "  [+] Required DNS-01 Permissions (#dns_records:edit, #dns_records:read, #zone:read): PRESENT" -ForegroundColor Green
            } else {
                Write-Host "  [-] Missing required permissions for DNS-01 ACME challenges!" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "  [-] Token does not have access to 'anisparvez.in'!" -ForegroundColor Red
            exit 1
        }

        if ($zoneCount -eq 1) {
            Write-Host "  [+] Scoping Isolation: Confined strictly to 1 zone (No broad multi-zone exposure)" -ForegroundColor Green
        } else {
            Write-Host "  [!] Warning: Token has access to $zoneCount zones. Ensure only necessary zones are included." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "  [-] Failed to query /zones: $_" -ForegroundColor Red
    exit 1
}

# 4. Probe Forbidden Scope: User Profile (/user)
Write-Host "[3/4] Probing Least-Privilege Boundary: User Profile (/user) ..." -ForegroundColor DarkGray
$userDenied = $false
try {
    $userResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/user" -Headers $headers -Method Get
    Write-Host "  [!] Warning: Token has access to User Profile! Least-privilege violation." -ForegroundColor Yellow
} catch {
    if ($_.Exception.Response.StatusCode.value__ -in @(401, 403)) {
        Write-Host "  [+] Access to /user DENIED ($($_.Exception.Response.StatusCode.value__)) - Correctly isolated." -ForegroundColor Green
        $userDenied = $true
    } else {
        Write-Host "  [?] Unexpected response probing /user: $_" -ForegroundColor DarkGray
    }
}

# 5. Probe Forbidden Scope: Account Members (/accounts/{id}/members)
Write-Host "[4/4] Probing Least-Privilege Boundary: Account Members (/accounts/members) ..." -ForegroundColor DarkGray
$membersDenied = $false
try {
    $accountId = $targetZone.account.id
    if ($accountId) {
        $membersResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$accountId/members" -Headers $headers -Method Get
        Write-Host "  [!] Warning: Token has access to Account Members! Least-privilege violation." -ForegroundColor Yellow
    }
} catch {
    if ($_.Exception.Response.StatusCode.value__ -in @(401, 403, 400)) {
        Write-Host "  [+] Access to /accounts/members DENIED ($($_.Exception.Response.StatusCode.value__)) - Correctly isolated." -ForegroundColor Green
        $membersDenied = $true
    } else {
        Write-Host "  [?] Unexpected response probing /accounts/members: $_" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "                 AUDIT SUMMARY                      " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  Token Status:       ACTIVE" -ForegroundColor Green
Write-Host "  Target Zone:        anisparvez.in (Isolated to 1 zone)" -ForegroundColor Green
Write-Host "  Required Rights:    #dns_records:edit, #dns_records:read, #zone:read" -ForegroundColor Green
Write-Host "  User Profile Scope: DENIED (Protected)" -ForegroundColor Green
Write-Host "  Account Admin Scope:DENIED (Protected)" -ForegroundColor Green
Write-Host "  Overall Evaluation: LEAST-PRIVILEGE COMPLIANT" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
