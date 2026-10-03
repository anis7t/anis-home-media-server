<#
    run_flutter_tests.ps1
    ---------------------
    Runs the Flutter client test suite with media_kit's orphaned temp state purged.

    WHY THIS EXISTS
    ---------------
    media_kit 1.2.6's NativeReferenceHolder persists one reference-buffer address in a temp file:

        %TEMP%\com.alexmercerind.media_kit.NativeReferenceHolder.$pid

    The file is created EMPTY and written afterwards, and media_kit never deletes it. Windows
    recycles PIDs, so a later `flutter test` process routinely inherits a PID a previous run used
    and finds that dead run's file. It then either

      * int.parse(''s) on the empty file   -> FormatException: Invalid number (at character 1), or
      * Pointer.fromAddress(<dead heap>)   -> reads 512 slots and hands them to the dispose
                                              callback, hanging every add()/remove() that awaits the
                                              never-completed _completer,

    and the whole test file reports "did not complete" rather than a clean assertion failure.

    Measured on this host: 415 orphaned files (70 zero-byte) spanning 2026-09-24..2026-10-03
    caused 2 failures in 6 runs, INCLUDING one `--concurrency=1` run. Note that serial execution is
    therefore NOT a fix on its own: the dominant cause is stale state surviving across runs.

    So this script purges before the run (guaranteeing a virgin state) and again afterwards in a
    finally block (so the run does not leave the next one a landmine). Purging afterwards is what
    actually stops the accumulation; a run aborted by Ctrl+C still leaves files, which is exactly
    why the pre-run purge exists too.

    This code path is gated behind `if (!kDebugMode) return;` in media_kit, so release APKs and
    on-device playback are unaffected - it is a host-test-only problem.

    USAGE
    -----
        .\scripts\run_flutter_tests.ps1                          # analyze + full suite, default concurrency
        .\scripts\run_flutter_tests.ps1 -Concurrency 1# serial
        .\scripts\run_flutter_tests.ps1 -SkipAnalyze             # suite only
        .\scripts\run_flutter_tests.ps1 -TestPath test/features # a subset
        .\scripts\run_flutter_tests.ps1 -PurgeOnly               # just clean up and report
#>
[CmdletBinding()]
param(
    [int]    $Concurrency = 0,
    [switch] $SkipAnalyze,
    [switch] $PurgeOnly,
    [string[]] $TestPath = @()
)

$ErrorActionPreference = 'Stop'

$ClientDir = Join-Path $PSScriptRoot '..\flutter_client'
$Flutter   = Join-Path $ClientDir 'flutter.bat'
if (-not (Test-Path $Flutter)) {
    # Fall back to whatever flutter is on PATH (the SDK may live elsewhere).
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "flutter not found. Expected '$Flutter' or flutter on PATH." }
    $Flutter = $cmd.Source
}

$HolderGlob = 'com.alexmercerind.media_kit.NativeReferenceHolder.*'

function Remove-MediaKitHolderState {
    param([string]$When)
    $stale = @(Get-ChildItem -Path $env:TEMP -Filter $HolderGlob -Force -ErrorAction SilentlyContinue)
    if ($stale.Count -eq 0) {
        Write-Host "  media_kit holder state ($When): nothing to purge." -ForegroundColor DarkGray
        return
    }
    $empty = @($stale | Where-Object { $_.Length -eq 0 }).Count
    # Only ever touches media_kit's own abandoned files. Skip any whose PID is a live process,
    # so this can never pull the rug from under a running flutter_tester.
    # NOTE: use .Name, not .BaseName - ".12584" is parsed as the extension, so BaseName would
    # yield "com.alexmercerind.media_kit.NativeReferenceHolder" and lose the pid entirely.
    $liveNames = @(
        $stale | Where-Object {
            $owner = [int]($_.Name -replace '^.*\.', '')
            [bool](Get-Process -Id $owner -ErrorAction SilentlyContinue)
        } | ForEach-Object { $_.Name }
    )
    foreach ($n in $liveNames) { Write-Host "  SKIPPING live PID file $n" -ForegroundColor Yellow }
    $doomed = @($stale | Where-Object { $liveNames -notcontains $_.Name })
    if ($doomed.Count) { $doomed | Remove-Item -Force -ErrorAction SilentlyContinue }
    Write-Host ("  media_kit holder state ({0}): purged {1} orphaned file(s) ({2} empty).{3}" -f `
        $When, $doomed.Count, $empty, $(if ($liveNames.Count) { " $($liveNames.Count) left (live PIDs)." } else { '' })) `
        -ForegroundColor Cyan
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '      Flutter Client Test Runner (media_kit safe)'   -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan

Write-Host "`n[1/4] Purging orphaned media_kit state before the run:" -ForegroundColor Yellow
Remove-MediaKitHolderState -When 'pre-run'

if ($PurgeOnly) {
    Write-Host "`n-PurgeOnly: done." -ForegroundColor Green
    exit 0
}

Push-Location $ClientDir
try {
    $exit = 0
    try {
        if (-not $SkipAnalyze) {
            Write-Host "`n[2/4] flutter analyze" -ForegroundColor Yellow
            & $Flutter analyze
            if ($LASTEXITCODE -ne 0) { $exit = $LASTEXITCODE }
        } else {
            Write-Host "`n[2/4] flutter analyze  (skipped)" -ForegroundColor Yellow
        }

        if ($exit -eq 0) {
            $label = if ($TestPath.Count) { $TestPath -join ' ' } else { '(full suite)' }
            Write-Host "`n[3/4] flutter test  $label" -ForegroundColor Yellow
            $args = @('test')
            if ($Concurrency -gt 0) { $args += @('--concurrency', $Concurrency) }
            if ($TestPath.Count) { $args += $TestPath }
            & $Flutter @args
            $exit = $LASTEXITCODE
        }
    }
    finally {
        # Always purge, including on Ctrl+C / crash: leaving files behind is what arms the
        # next run's PID-reuse landmine.
        Write-Host "`n[4/4] Purging orphaned media_kit state after the run:" -ForegroundColor Yellow
        Remove-MediaKitHolderState -When 'post-run'
    }
}
finally {
    Pop-Location
}

Write-Host ''
if ($exit -eq 0) {
    Write-Host 'RESULT: PASS' -ForegroundColor Green
} else {
    Write-Host "RESULT: FAIL (exit $exit)" -ForegroundColor Red
}
exit $exit