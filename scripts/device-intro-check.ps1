param(
  [Parameter(Mandatory = $true)][string]$Device,
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$OutDir = 'E:\MediaServer\docs\opening-sequence\device',
  [int]$Shots = 6
)

# The on-device check: the intro, on real hardware.
#
# The intro plays on EVERY launch (D15), so a force-stop and a launch is
# enough to see it - and no key event is sent, so the remote is never taken
# over.
$ErrorActionPreference = 'SilentlyContinue'
$adb = 'D:\platform-tools-latest-windows\platform-tools\adb.exe'
$pkg = 'in.anisparvez.media_server_client'
$activity = 'in.anisparvez.media_server_client.MainActivity'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "== $Name ($Device) =="

# The audio state, sampled while the intro runs.
& $adb -s $Device shell dumpsys audio > "$OutDir/$Name-audio-during.txt" 2>&1

# A cold launch: force-stop, then start.
& $adb -s $Device shell am force-stop $pkg | Out-Null
Start-Sleep -Milliseconds 400
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $adb -s $Device shell am start -n "$pkg/$activity" | Out-Null

# The intro runs for three seconds. Grab frames while it does.
for ($i = 0; $i -lt $Shots; $i++) {
  $ms = [int]$sw.ElapsedMilliseconds
  $remote = "/sdcard/intro-$Name-$i.png"
  & $adb -s $Device shell screencap -p $remote | Out-Null
  & $adb -s $Device pull $remote "$OutDir/$Name-$i.png" | Out-Null
  & $adb -s $Device shell rm -f $remote | Out-Null
  Write-Host ("   shot {0} at {1} ms" -f $i, $ms)
  if ($i -eq 1) {
    & $adb -s $Device shell dumpsys audio > "$OutDir/$Name-audio-mid.txt" 2>&1
  }
  Start-Sleep -Milliseconds 120
}

# And the state after the sequence has finished.
Start-Sleep -Seconds 3
& $adb -s $Device shell screencap -p "/sdcard/intro-$Name-after.png" | Out-Null
& $adb -s $Device pull "/sdcard/intro-$Name-after.png" "$OutDir/$Name-after.png" | Out-Null
& $adb -s $Device shell rm -f "/sdcard/intro-$Name-after.png" | Out-Null

Write-Host "   the audio player state, as the intro ran:"
Select-String -Path "$OutDir/$Name-audio-mid.txt" -Pattern 'state:started|AudioPlaybackConfiguration|piid:' |
  Select-Object -First 4 | ForEach-Object { "     $($_.Line.Trim())" }
