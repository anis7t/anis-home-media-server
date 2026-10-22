<#
    fetch_libmpv.ps1
    ----------------
    Provisions the libmpv-2.dll that media_kit's Windows backend needs, so that the
    Flutter host-side tests can load it inside a plain `flutter test` process.

    WHY THIS EXISTS
    ---------------
    Three Flutter test files call MediaKit.ensureInitialized():

        test/features/player/runtime_player_3a_test.dart
        test/features/player/runtime_player_3b_test.dart
        test/features/shell/app_shell_test.dart

    On this host the DLL is not on PATH, so all three fail in setUpAll with

        Exception: Cannot find libmpv-2.dll in your system %PATH%.

    The shipped client targets Android (media_kit uses the Android backend there), so
    this is a host-test-only problem - the APK, the release build and on-device
    playback are unaffected.

    All three tests already prefer this exact path, which is where this script puts it:

        flutter_client/build/windows/x64/runner/Release/libmpv-2.dll

    THAT PATH IS GITIGNORED. Nothing fetched here is ever committed.

    WHAT IT FETCHES, AND WHY THAT ARTIFACT
    --------------------------------------
    Exactly the archive our own dependency already pins.
    media_kit_libs_windows_video 1.0.11's windows/CMakeLists.txt downloads this file
    and checks this MD5 during a normal Windows build:

        mpv-dev-x86_64-20230924-git-652a1dd.7z
        https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/
        MD5 a832ef24b3a6ff97cd2560b5b9d04cd8

    The archive is verified against that MD5 BEFORE extraction, and the script fails
    closed on any mismatch. It never falls back to an unverified download.

    USAGE
    -----
        .\scripts\fetch_libmpv.ps1              # provision if missing (idempotent)
        .\scripts\fetch_libmpv.ps1 -Force       # re-download and re-extract
        .\scripts\fetch_libmpv.ps1 -VerifyOnly  # report state, change nothing

    Re-run it after `flutter clean`, which deletes flutter_client/build/.
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $VerifyOnly
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DllPath = Join-Path $RepoRoot 'flutter_client\build\windows\x64\runner\Release\libmpv-2.dll'
$CacheDir = Join-Path $env:LOCALAPPDATA 'MediaServer\tooling\libmpv'

$ArchiveName = 'mpv-dev-x86_64-20230924-git-652a1dd.7z'
$ArchiveUrl = 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/' + $ArchiveName
$ArchiveMd5 = 'a832ef24b3a6ff97cd2560b5b9d04cd8'

function Get-Md5([string] $Path) {
    return (Get-FileHash -Path $Path -Algorithm MD5).Hash.ToLowerInvariant()
}

function Show-DllState([string] $Path) {
    $item = Get-Item -LiteralPath $Path
    $sha256 = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host ("  path   : {0}" -f $item.FullName)
    Write-Host ("  size   : {0:N0} bytes" -f $item.Length)
    Write-Host ("  sha256 : {0}" -f $sha256)
}

Write-Host 'fetch_libmpv: media_kit Windows runtime for Flutter host tests'

if ($VerifyOnly) {
    if (Test-Path -LiteralPath $DllPath) {
        Write-Host '  state  : present'
        Show-DllState $DllPath
        exit 0
    }
    Write-Host '  state  : MISSING'
    Write-Host ("  expected at {0}" -f $DllPath)
    exit 1
}

if ((Test-Path -LiteralPath $DllPath) -and -not $Force) {
    Write-Host '  state  : already present, nothing to do'
    Show-DllState $DllPath
    Write-Host '  (pass -Force to re-download)'
    exit 0
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$ArchivePath = Join-Path $CacheDir $ArchiveName

$archiveValid = $false
if (Test-Path -LiteralPath $ArchivePath) {
    $existing = Get-Md5 $ArchivePath
    if ($existing -eq $ArchiveMd5) {
        Write-Host '  archive: cached copy verified'
        $archiveValid = $true
    } else {
        Write-Host ("  archive: cached copy has MD5 {0}, discarding" -f $existing)
        Remove-Item -LiteralPath $ArchivePath -Force
    }
}

if (-not $archiveValid) {
    Write-Host '  archive: downloading'
    Write-Host ("           {0}" -f $ArchiveUrl)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw 'curl.exe is required to download the archive (or download it manually into the cache dir).'
    }
    & $curl.Source -L --fail --retry 3 --silent --show-error -o $ArchivePath $ArchiveUrl
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        throw ("download failed (curl exit {0}); nothing was provisioned" -f $LASTEXITCODE)
    }

    $actual = Get-Md5 $ArchivePath
    if ($actual -ne $ArchiveMd5) {
        Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
        throw ("MD5 mismatch: expected {0}, got {1}. Archive deleted; nothing was provisioned." -f $ArchiveMd5, $actual)
    }
    Write-Host '  archive: download verified (MD5 matches the pin)'
}

$ExtractDir = Join-Path $CacheDir 'extracted'
if (Test-Path -LiteralPath $ExtractDir) {
    Remove-Item -LiteralPath $ExtractDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) {
    throw 'tar.exe (bsdtar) is required to unpack the .7z archive.'
}
Write-Host '  extract: unpacking archive'
& $tar.Source -xf $ArchivePath -C $ExtractDir
if ($LASTEXITCODE -ne 0) {
    throw ("tar failed to unpack the archive (exit {0})" -f $LASTEXITCODE)
}

$source = Get-ChildItem -LiteralPath $ExtractDir -Recurse -Filter 'libmpv-2.dll' |
    Select-Object -First 1
if (-not $source) {
    throw 'libmpv-2.dll was not found inside the archive; nothing was provisioned.'
}

$destDir = Split-Path -Parent $DllPath
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Copy-Item -LiteralPath $source.FullName -Destination $DllPath -Force

if ((Get-Md5 $DllPath) -ne (Get-Md5 $source.FullName)) {
    Remove-Item -LiteralPath $DllPath -Force -ErrorAction SilentlyContinue
    throw 'copied DLL does not match the extracted file; nothing was provisioned.'
}

Write-Host '  state  : provisioned'
Show-DllState $DllPath
Write-Host '  Flutter host tests will now find it at the path they already prefer.'
