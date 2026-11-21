# deploy_dual_gpu_service.ps1
# Deploys fresh media-server-api.exe and enables Dual-GPU & GPU diagnostic logs in MediaServerRust

$ErrorActionPreference = "Stop"

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\MediaServerRust\Parameters"
$srcBinary = "E:\MediaServer\rust\target\release\media-server-api.exe"
$destBinary = "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe"
$backupBinary = "E:\MediaServer\cache\release-build\dual-gpu-validation\release\media-server-api.exe.bak"
$envPath = "E:\MediaServer\.env"

Write-Host "=== 1. Checking source binary ==="
if (-not (Test-Path $srcBinary)) {
    throw "Source binary not found at $srcBinary"
}
$srcItem = Get-Item $srcBinary
Write-Host "Source binary size: $($srcItem.Length) bytes, LastWriteTime: $($srcItem.LastWriteTime)"

Write-Host "=== 2. Stopping MediaServerRust service ==="
Stop-Service -Name "MediaServerRust" -Force -ErrorAction SilentlyContinue
$timeout = 15
while ($timeout -gt 0) {
    $svc = Get-Service -Name "MediaServerRust"
    if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        break
    }
    Start-Sleep -Seconds 1
    $timeout--
}
Write-Host "MediaServerRust status: $((Get-Service -Name 'MediaServerRust').Status)"

Write-Host "=== 3. Deploying updated release binary ==="
if (Test-Path $destBinary) {
    Copy-Item -Path $destBinary -Destination $backupBinary -Force
    Write-Host "Backed up existing binary to $backupBinary"
}
Copy-Item -Path $srcBinary -Destination $destBinary -Force
$destItem = Get-Item $destBinary
Write-Host "Deployed binary size: $($destItem.Length) bytes, LastWriteTime: $($destItem.LastWriteTime)"

Write-Host "=== 4. Updating .env configuration ==="
if (Test-Path $envPath) {
    $envContent = Get-Content -Path $envPath
    $updatedEnv = $envContent -replace 'MEDIA_SERVER_ENABLE_DUAL_GPU=0', 'MEDIA_SERVER_ENABLE_DUAL_GPU=1'
    Set-Content -Path $envPath -Value $updatedEnv
    Write-Host "Updated MEDIA_SERVER_ENABLE_DUAL_GPU=1 in $envPath"
}

Write-Host "=== 5. Updating NSSM AppEnvironmentExtra ==="
$currentParams = Get-ItemProperty -Path $regPath
$currentEnv = $currentParams.AppEnvironmentExtra

$newEnv = [System.Collections.Generic.List[string]]::new()
foreach ($line in $currentEnv) {
    if ($line -like "RUST_LOG=*") {
        $newEnv.Add("RUST_LOG=info,media_server_api::services::media_pipeline::gpu_service=debug,media_server_api::services::media_pipeline::transcode_worker=debug,media_server_api::services::media_pipeline::gpu_thermal=debug")
        Write-Host "Updated RUST_LOG filter"
    } elseif ($line -like "MEDIA_SERVER_ENABLE_DUAL_GPU=*") {
        continue
    } elseif ($line.Trim().Length -gt 0) {
        $newEnv.Add($line)
    }
}
$newEnv.Add("MEDIA_SERVER_ENABLE_DUAL_GPU=1")

Set-ItemProperty -Path $regPath -Name "AppEnvironmentExtra" -Value $newEnv.ToArray() -Type MultiString
Write-Host "Registry updated successfully."

Write-Host "=== 6. Starting MediaServerRust service ==="
Start-Service -Name "MediaServerRust"
$timeout = 15
while ($timeout -gt 0) {
    $svc = Get-Service -Name "MediaServerRust"
    if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
        break
    }
    Start-Sleep -Seconds 1
    $timeout--
}

$finalSvc = Get-Service -Name "MediaServerRust"
Write-Host "MediaServerRust is now: $($finalSvc.Status)"

if ($finalSvc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
    throw "MediaServerRust failed to reach Running state"
}

Write-Host "=== Deployment Complete ==="
