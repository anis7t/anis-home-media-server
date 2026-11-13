# Update Cloudflare DNS A-record for media.anisparvez.in

param(
    [string]$Domain = "media.anisparvez.in",
    [string]$ZoneName = "anisparvez.in",
    [string]$NewIp = "223.235.84.179",
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"

if (-not $Token) {
    if (Test-Path "E:\MediaServer\Caddyfile") {
        $content = Get-Content "E:\MediaServer\Caddyfile"
        foreach ($line in $content) {
            if ($line -match 'dns\s+cloudflare\s+([A-Za-z0-9_\-]+)') {
                $Token = $matches[1].Trim()
                break
            }
        }
    }
}

if (-not $Token) {
    throw "Cloudflare API token not found."
}

$headers = @{
    "Authorization" = ("Bearer " + $Token)
    "Content-Type"  = "application/json"
}

Write-Host "Fetching Cloudflare zones..." -ForegroundColor Cyan
$zonesResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones" -Headers $headers -Method Get
$zone = $zonesResp.result | Where-Object { $_.name -eq $ZoneName }
if (-not $zone) { throw "Zone $ZoneName not found." }
$zoneId = $zone.id
Write-Host "Found Zone '$ZoneName' (ID: $zoneId)" -ForegroundColor Green

Write-Host "Querying DNS A-record for $Domain..." -ForegroundColor Cyan
$dnsResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?name=$Domain" -Headers $headers -Method Get
$record = $dnsResp.result | Where-Object { $_.type -eq "A" }
if (-not $record) { throw "A-record for $Domain not found." }

Write-Host "Current DNS A-record: $($record.name) -> $($record.content) (Proxied: $($record.proxied))" -ForegroundColor Yellow

if ($record.content -eq $NewIp) {
    Write-Host "DNS A-record already points to $NewIp. No update needed." -ForegroundColor Green
    exit 0
}

Write-Host "Updating DNS A-record to $NewIp..." -ForegroundColor Cyan
$body = @{
    type    = "A"
    name    = $Domain
    content = $NewIp
    ttl     = 300
    proxied = $record.proxied
} | ConvertTo-Json

$putResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$($record.id)" -Headers $headers -Method Put -Body $body
if ($putResp.success) {
    Write-Host "SUCCESS: Cloudflare DNS A-record updated!" -ForegroundColor Green
    Write-Host "  Name:    $($putResp.result.name)" -ForegroundColor Green
    Write-Host "  IP:      $($putResp.result.content)" -ForegroundColor Green
    Write-Host "  Proxied: $($putResp.result.proxied)" -ForegroundColor Green
    Write-Host "  TTL:     $($putResp.result.ttl)" -ForegroundColor Green
} else {
    throw "Update failed: $($putResp.errors | ConvertTo-Json)"
}
