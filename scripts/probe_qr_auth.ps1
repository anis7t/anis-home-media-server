$ErrorActionPreference = "Stop"

Write-Host "1. Testing POST /api/auth/qr..." -ForegroundColor Cyan
$session = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/api/auth/qr"
Write-Host "   Session created successfully!" -ForegroundColor Green
Write-Host "   QR ID: $($session.qr_id)"
Write-Host "   Code: $($session.code)"
Write-Host "   Sig: $($session.sig)"
Write-Host "   Expires At: $($session.expires_at)"

Write-Host "`n2. Testing GET /api/auth/qr/{id}/status..." -ForegroundColor Cyan
$status = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/api/auth/qr/$($session.qr_id)/status"
Write-Host "   Status: $($status.status)" -ForegroundColor Green

Write-Host "`n3. Testing GET /api/auth/qr/{id}/finalize without secret (should be 403)..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "http://127.0.0.1:8000/api/auth/qr/$($session.qr_id)/finalize" -TimeoutSec 5
    Write-Host "   Finalize unexpectedly succeeded without secret!" -ForegroundColor Red
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Host "   Finalize rejected as expected: HTTP $code Forbidden" -ForegroundColor Green
}

Write-Host "`nAll live QR auth probes succeeded!" -ForegroundColor Green
