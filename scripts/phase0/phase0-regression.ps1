[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$ComposeShutdownRepetitions = 5,
    [switch]$ReuseBuildCache,
    [ValidatePattern('^[0-9]{14}-[0-9]{4}$')]
    [string]$CleanupRunId,
    [switch]$KubernetesOnly,
    [string]$TempDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http, System.Web.Extensions -ErrorAction SilentlyContinue

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$script:Kubectl = 'C:\Program Files\Docker\Docker\resources\bin\kubectl.exe'
$script:RunId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + (Get-Random -Minimum 1000 -Maximum 9999)
$script:TempParent = if ($TempDirectory) {
    [System.IO.Path]::GetFullPath($TempDirectory)
} elseif ($env:PHASE0_TEMP_DIR) {
    [System.IO.Path]::GetFullPath($env:PHASE0_TEMP_DIR)
} elseif (Test-Path 'E:\tmp') {
    'E:\tmp'
} else {
    [System.IO.Path]::GetFullPath($env:TEMP)
}
$script:TempRoot = Join-Path $script:TempParent "media-server-phase0-$($script:RunId)"
$script:Snapshot = Join-Path $script:TempRoot 'source'
$script:Logs = Join-Path $script:TempRoot 'logs'
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Redactions = [System.Collections.Generic.List[string]]::new()
$script:ComposeProjects = [System.Collections.Generic.List[object]]::new()
$script:CreatedNamespace = $null
$script:TempRootCreated = $false
$script:OriginalPath = $env:PATH
$script:CreatedImages = [System.Collections.Generic.List[string]]::new()
$script:ImportedKubernetesImages = [System.Collections.Generic.List[string]]::new()
$script:DisposableDbContainers = [System.Collections.Generic.List[string]]::new()
$script:DisposableNetworks = [System.Collections.Generic.List[string]]::new()
$script:PortForwards = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$script:CleanupWarnings = [System.Collections.Generic.List[string]]::new()

function Write-Phase0Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$State,
        [Parameter()][object]$Evidence
    )
    $item = [pscustomobject]@{
        name = $Name
        state = $State
        evidence = $Evidence
    }
    $script:Results.Add($item)
    Write-Host "[$State] $Name"
}

function Assert-Phase0 {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Logged {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$LogPath
    )
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments *> $LogPath
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($Operation -in @('Cache-independent default image build', 'Cached default image build')) {
            $tail = (Get-Content -LiteralPath $LogPath -Tail 60 -ErrorAction SilentlyContinue) -join "`n"
            throw "$Operation failed with exit code $exitCode. Build-only diagnostic output:`n$tail"
        }
        if ($Operation -eq 'Probe shipped Android API contract against isolated Compose service') {
            $tail = (Get-Content -LiteralPath $LogPath -Tail 60 -ErrorAction SilentlyContinue) -join "`n"
            throw "$Operation failed with exit code $exitCode. Endpoint-only diagnostic output:`n$tail"
        }
        if ($Operation -eq 'Run full Rust unit and integration suite against disposable PostgreSQL') {
            $tail = (Get-Content -LiteralPath $LogPath -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
            foreach ($secret in $script:Redactions) { if ($secret) { $tail = $tail.Replace($secret, '[redacted]') } }
            throw "$Operation failed with exit code $exitCode. Redacted test-only diagnostic output:`n$tail"
        }
        throw "$Operation failed with exit code $exitCode. Captured output was kept private and will be removed by cleanup."
    }
}

function Get-NativeText {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation
    )
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable @Arguments 2>&1)
    }
    finally {
        $ErrorActionPreference = $prev
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Operation failed with exit code $exitCode."
    }
    return ($output -join "`n").Trim()
}

function Invoke-DockerText {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Operation)
    return Get-NativeText -Executable $script:Docker -Arguments $Arguments -Operation $Operation
}

function Invoke-KubectlText {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Operation)
    return Get-NativeText -Executable $script:Kubectl -Arguments $Arguments -Operation $Operation
}

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Start-KubernetesApiPortForward {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$LogSuffix
    )
    $forwardPort = Get-FreeLoopbackPort
    $portForwardOut = Join-Path $script:Logs "kubernetes-port-forward-$LogSuffix.out.log"
    $portForwardErr = Join-Path $script:Logs "kubernetes-port-forward-$LogSuffix.err.log"
    $portForward = Start-Process -FilePath $script:Kubectl -ArgumentList @('--context', 'docker-desktop', '--namespace', $Namespace, 'port-forward', "service/$Release", "$($forwardPort):8000", '--address', '127.0.0.1') -WindowStyle Hidden -PassThru -RedirectStandardOutput $portForwardOut -RedirectStandardError $portForwardErr
    $script:PortForwards.Add($portForward)
    $origin = "http://127.0.0.1:$forwardPort"
    $null = Wait-HttpStatus -Uri "$origin/health" -ExpectedStatus 200 -TimeoutSeconds 120
    return $origin
}

function Stop-KubernetesApiPortForward {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    if (-not $Process.HasExited) {
        try {
            $Process.Kill($true)
        }
        catch {
            $Process.Kill()
        }
        $Process.WaitForExit(5000) | Out-Null
    }
    if (-not $Process.HasExited) { throw 'The replaced Kubernetes API port-forward is still active after termination.' }
    $script:PortForwards.Remove($Process) | Out-Null
}

function New-TestSecret {
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $secret = [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
    $script:Redactions.Add($secret)
    return $secret
}

function Write-PrivateText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Http {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][ValidateSet('GET', 'POST', 'DELETE', 'PUT', 'HEAD')][string]$Method = 'GET',
        [Parameter()][hashtable]$Headers = @{},
        [Parameter()][AllowNull()][object]$Body = $null,
        [Parameter()][string]$ContentType = 'application/json',
        [Parameter()][int]$TimeoutSeconds = 60
    )
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    $response = $null
    try {
        foreach ($name in $Headers.Keys) {
            $null = $request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name])
        }
        if ($null -ne $Body) {
            if ($Body -is [byte[]]) {
                $request.Content = [System.Net.Http.ByteArrayContent]::new($Body)
            }
            else {
                $request.Content = [System.Net.Http.StringContent]::new([string]$Body, [System.Text.Encoding]::UTF8)
            }
            $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $responseHeaders = @{}
        foreach ($header in $response.Headers) {
            $responseHeaders[[string]$header.Key] = [string]::Join(', ', $header.Value)
        }
        foreach ($header in $response.Content.Headers) {
            $responseHeaders[[string]$header.Key] = [string]::Join(', ', $header.Value)
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
            Headers = $responseHeaders
        }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Wait-HttpStatus {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][int]$ExpectedStatus,
        [Parameter()][int]$TimeoutSeconds = 180,
        [Parameter()][hashtable]$Headers = @{}
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-Http -Uri $Uri -Method 'GET' -Headers $Headers -TimeoutSeconds 5
            if ([int]$response.StatusCode -eq $ExpectedStatus) {
                return $response
            }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
        Start-Sleep -Milliseconds 250
    }
    throw "HTTP endpoint did not return the expected status $ExpectedStatus within $TimeoutSeconds seconds: $Uri"
}

function Get-ComposePrefix {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter()][string]$OverrideFile
    )
    $prefix = @(
        'compose', '--project-name', $Project,
        '--project-directory', $script:Snapshot,
        '--env-file', $EnvironmentFile,
        '--file', (Join-Path $script:Snapshot 'compose.yaml')
    )
    if ($OverrideFile) {
        $prefix += @('--file', $OverrideFile)
    }
    return ,$prefix
}

function ConvertFrom-Phase0Json {
    param([Parameter(Mandatory)][string]$Json)
    try {
        return $Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $serializer.MaxJsonLength = [int]::MaxValue
        return $serializer.DeserializeObject($Json)
    }
}

function Get-ComposeConfig {
    param([Parameter(Mandatory)][string[]]$Prefix, [Parameter(Mandatory)][string]$Label)
    $json = Get-NativeText -Executable $script:Docker -Arguments ($Prefix + @('config', '--format', 'json')) -Operation "$Label Compose config"
    return ConvertFrom-Phase0Json $json
}

function Wait-ComposeHealthy {
    param([Parameter(Mandatory)][string[]]$Prefix, [Parameter(Mandatory)][string[]]$Services, [Parameter()][int]$TimeoutSeconds = 240)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $allHealthy = $true
        foreach ($service in $Services) {
            $id = Get-NativeText -Executable $script:Docker -Arguments ($Prefix + @('ps', '-q', $service)) -Operation "Find Compose $service container"
            if (-not $id) {
                $allHealthy = $false
                break
            }
            $health = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', $id) -Operation "Inspect Compose $service health"
            if ($health -ne 'healthy') {
                $allHealthy = $false
                break
            }
        }
        if ($allHealthy) {
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "Compose services did not become healthy within $TimeoutSeconds seconds."
}

function Wait-ContainerStopped {
    param([Parameter(Mandatory)][string]$ContainerId, [Parameter()][int]$TimeoutSeconds = 240)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $running = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{.State.Running}}', $ContainerId) -Operation 'Inspect API container state'
        if ($running -eq 'false') {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "API container did not stop within $TimeoutSeconds seconds."
}

function Get-Phase0RelativePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$FullPath
    )
    $normalizedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $normalizedFull = [System.IO.Path]::GetFullPath($FullPath)
    if ($normalizedFull.StartsWith($normalizedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedFull.Substring($normalizedBase.Length).Replace('\', '/')
    }
    return [System.IO.Path]::GetFileName($normalizedFull)
}

function New-SourceSnapshot {
    $tracked = @(& git -C $script:RepoRoot ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate tracked source files.'
    }
    $untracked = @(& git -C $script:RepoRoot ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate non-ignored untracked source files.'
    }

    $relativePaths = @($tracked + $untracked | Sort-Object -Unique)
    foreach ($relativePath in $relativePaths) {
        $normalized = $relativePath.Replace('\', '/')
        if ($normalized -match '(^|/)\.env($|\.)|(^|/)(secrets|\.secrets)(/|$)|(^|/)\.git(/|$)') {
            continue
        }
        $source = Join-Path $script:RepoRoot $relativePath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            continue
        }
        $destination = Join-Path $script:Snapshot $relativePath
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $revision = Get-NativeText -Executable 'git' -Arguments @('-C', $script:RepoRoot, 'rev-parse', 'HEAD') -Operation 'Read source revision'
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    Get-ChildItem -LiteralPath $script:Snapshot -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = Get-Phase0RelativePath -BasePath $script:Snapshot -FullPath $_.FullName
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestLines.Add("$hash`t$relative")
    }
    $manifestPath = Join-Path $script:TempRoot 'source-manifest.sha256'
    Write-PrivateText -Path $manifestPath -Text (($manifestLines -join "`n") + "`n")
    $snapshotHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $contextFiles = @(
        (Get-ChildItem -LiteralPath $script:Snapshot -File -Recurse | Where-Object {
            $rel = Get-Phase0RelativePath -BasePath $script:Snapshot -FullPath $_.FullName
            $rel -eq 'Dockerfile' -or $rel -eq '.dockerignore' -or
            ($rel.StartsWith('rust/') -and $rel -notmatch '(^|/)(target|node_modules)(/|$)') -or
            ($rel.StartsWith('web/') -and $rel -notmatch '(^|/)(node_modules|dist|e2e|test-results|playwright-report)(/|$)')
        })
    )
    $suspicious = @($contextFiles | Where-Object {
        $_.Name -match '(?i)^\.env($|\.)|\.db($|-shm$|-wal$)|\.(mp4|mkv|m4v|webm|mov|avi|jpg|jpeg|png)$|\.log$' -or
        $_.FullName -match '(?i)\\(cache|backups|updates|secrets|\.docker)(\\|$)'
    })
    Assert-Phase0 -Condition ($suspicious.Count -eq 0) -Message 'The Docker context contains a secret, database, media file, cache, or unrelated local artifact.'

    $contextBytes = ($contextFiles | Measure-Object -Property Length -Sum).Sum
    return [pscustomobject]@{
        revision = $revision
        snapshotSha256 = $snapshotHash
        snapshotFileCount = $manifestLines.Count
        contextFileCount = $contextFiles.Count
        contextBytes = [int64]$contextBytes
    }
}

function Write-ComposeEnvironment {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$HttpPort,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DatabasePassword,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AppSecret,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MediaPath,
        [Parameter()][string]$GoogleClientId = '',
        [Parameter()][string]$GoogleClientSecret = ''
    )
    $forwardMedia = $MediaPath.Replace('\', '/')
    $contents = @(
        'MEDIA_DOCKER_DB_NAME=media_server'
        'MEDIA_DOCKER_DB_USER=media_server'
        "MEDIA_DOCKER_DB_PASSWORD=$DatabasePassword"
        "MEDIA_DOCKER_APP_SECRET=$AppSecret"
        "MEDIA_DOCKER_HTTP_PORT=$HttpPort"
        "MEDIA_DOCKER_PUBLIC_BASE_URL=http://127.0.0.1:$HttpPort"
        "MEDIA_DOCKER_MEDIA_PATH=$forwardMedia"
        'MEDIA_DOCKER_ADMIN_EMAILS=phase0-admin@example.test'
        "MEDIA_DOCKER_GOOGLE_CLIENT_ID=$GoogleClientId"
        "MEDIA_DOCKER_GOOGLE_CLIENT_SECRET=$GoogleClientSecret"
        "PHASE0_OAUTH_CLIENT_ID=$GoogleClientId"
        "PHASE0_OAUTH_CLIENT_SECRET=$GoogleClientSecret"
    ) -join "`n"
    Write-PrivateText -Path $Path -Text ($contents + "`n")
}

function Write-ComposeImageOverride {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Image)
    $yaml = @"
services:
  api:
    image: $Image
    pull_policy: never
"@
    Write-PrivateText -Path $Path -Text $yaml
}

function Write-ComposeOAuthOverride {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ApiImage, [Parameter(Mandatory)][string]$MockImage)
    $dollar = [char]36
    $yaml = @"
services:
  api:
    image: $ApiImage
    pull_policy: never
    environment:
      MEDIA_SERVER_AUTH_ALLOWLIST: "phase0-admin@example.test,phase0-viewer@example.test"
      MEDIA_SERVER_TRANSCODE_PRESET: veryslow
  phase0-oauth-mock:
    image: $MockImage
    pull_policy: never
    environment:
      PHASE0_MOCK_CLIENT_ID: ${dollar}{PHASE0_OAUTH_CLIENT_ID}
      PHASE0_MOCK_CLIENT_SECRET: ${dollar}{PHASE0_OAUTH_CLIENT_SECRET}
    expose:
      - "8080"
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "http://127.0.0.1:8080/health"]
      interval: 5s
      timeout: 2s
      retries: 12
      start_period: 5s
"@
    Write-PrivateText -Path $Path -Text $yaml
}

function Wait-ForOAuthCallbackCookie {
    param([Parameter(Mandatory)][string]$Origin, [Parameter(Mandatory)][string]$Code)
    $start = Invoke-Http -Uri "$Origin/auth/google?next=%2F" -Method GET
    Assert-Phase0 -Condition ([int]$start.StatusCode -eq 307) -Message 'OAuth start did not return a temporary redirect.'
    $location = [string]$start.Headers['Location']
    Assert-Phase0 -Condition ($location.StartsWith('http://phase0-oauth-mock:8080/o/oauth2/v2/auth')) -Message 'The feature-gated API did not redirect to the private OAuth mock.'
    $state = $null
    foreach ($pair in ([Uri]$location).Query.TrimStart('?').Split('&')) {
        $parts = $pair.Split('=', 2)
        if ($parts.Count -eq 2 -and $parts[0] -eq 'state') {
            $state = [Uri]::UnescapeDataString($parts[1])
            break
        }
    }
    Assert-Phase0 -Condition (-not [string]::IsNullOrWhiteSpace($state)) -Message 'OAuth state was missing from the provider redirect.'
    $encodedState = [Uri]::EscapeDataString($state)
    $callback = Invoke-Http -Uri "$Origin/auth/google/callback?code=$Code&state=$encodedState" -Method GET
    return $callback
}

function Get-SessionCookie {
    param([Parameter(Mandatory)]$CallbackResponse)
    Assert-Phase0 -Condition ([int]$CallbackResponse.StatusCode -eq 307) -Message "OAuth callback failed with HTTP $($CallbackResponse.StatusCode)."
    $setCookie = [string]$CallbackResponse.Headers['Set-Cookie']
    $match = [regex]::Match($setCookie, 'session_token=([^;]+)')
    Assert-Phase0 -Condition $match.Success -Message 'Successful OAuth callback did not set a session cookie.'
    return "session_token=$($match.Groups[1].Value)"
}

function Wait-ForApiContainer {
    param([Parameter(Mandatory)][string[]]$Prefix, [Parameter(Mandatory)][string]$Origin)
    Wait-ComposeHealthy -Prefix $Prefix -Services @('postgres', 'api')
    $null = Wait-HttpStatus -Uri "$Origin/health" -ExpectedStatus 200 -TimeoutSeconds 180
    $id = Get-NativeText -Executable $script:Docker -Arguments ($Prefix + @('ps', '-q', 'api')) -Operation 'Find API container'
    Assert-Phase0 -Condition ($id -match '^[a-f0-9]+$') -Message 'Compose API container ID was not returned.'
    return $id
}

function New-SyntheticMedia {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Duration,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][string]$SubtitlePath
    )
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    $inputVideo = "testsrc2=size=$Size`:rate=24`:duration=$Duration"
    $inputAudio = "sine=frequency=997`:sample_rate=48000`:duration=$Duration"
    $args = @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', $inputVideo, '-f', 'lavfi', '-i', $inputAudio)
    if ($SubtitlePath) {
        $args += @('-i', $SubtitlePath, '-map', '0:v:0', '-map', '1:a:0', '-map', '2:s:0')
    }
    else {
        $args += @('-map', '0:v:0', '-map', '1:a:0')
    }
    $args += @('-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-crf', '30', '-pix_fmt', 'yuv420p', '-c:a', 'aac')
    if ($SubtitlePath) {
        $args += @('-c:s', 'srt', '-metadata:s:s:0', 'language=eng')
    }
    $args += @('-shortest', $Path)
    Invoke-Logged -Executable $ffmpeg -Arguments $args -Operation "Generate disposable media fixture" -LogPath (Join-Path $script:Logs 'ffmpeg-fixture.log')
}

function Build-Phase0Images {
    param([Parameter(Mandatory)][string]$RevisionTag, [Parameter()][switch]$ReuseBuildCache)
    $defaultImage = "media-server-api:phase0-$RevisionTag"
    $oauthImage = "media-server-api:phase0-oauth-test-$RevisionTag"
    $mockImage = "media-server-oauth-mock:phase0-$RevisionTag"
    foreach ($image in @($defaultImage, $oauthImage, $mockImage)) {
        $existingImageId = Get-NativeText -Executable $script:Docker -Arguments @('images', '--quiet', $image) -Operation "Check unique image tag $image"
        Assert-Phase0 -Condition (-not $existingImageId) -Message "The generated Phase 0 image tag already exists; refusing to overwrite $image."
    }
    $script:CreatedImages.Add($defaultImage)
    $script:CreatedImages.Add($oauthImage)
    $script:CreatedImages.Add($mockImage)

    $defaultBuildSeconds = [System.Diagnostics.Stopwatch]::StartNew()
    $defaultBuildArguments = @('build')
    if (-not $ReuseBuildCache) { $defaultBuildArguments += '--no-cache' }
    $defaultBuildArguments += @('--progress=plain', '--target', 'final', '--tag', $defaultImage, $script:Snapshot)
    $defaultBuildOperation = if ($ReuseBuildCache) { 'Cached default image build' } else { 'Cache-independent default image build' }
    Invoke-Logged -Executable $script:Docker -Arguments $defaultBuildArguments -Operation $defaultBuildOperation -LogPath (Join-Path $script:Logs 'docker-build-default.log')
    $defaultBuildSeconds.Stop()

    Invoke-Logged -Executable $script:Docker -Arguments @('build', '--progress=plain', '--target', 'phase0-oauth-api', '--tag', $oauthImage, $script:Snapshot) -Operation 'Build feature-gated OAuth test API image' -LogPath (Join-Path $script:Logs 'docker-build-oauth-api.log')
    Invoke-Logged -Executable $script:Docker -Arguments @('build', '--progress=plain', '--target', 'phase0-oauth-mock', '--tag', $mockImage, $script:Snapshot) -Operation 'Build feature-gated OAuth mock image' -LogPath (Join-Path $script:Logs 'docker-build-oauth-mock.log')

    foreach ($image in @($defaultImage, $oauthImage, $mockImage)) {
        $inspectJson = Get-NativeText -Executable $script:Docker -Arguments @('image', 'inspect', $image) -Operation "Inspect image $image"
        $inspect = @($inspectJson | ConvertFrom-Json)[0]
        Assert-Phase0 -Condition ($inspect.Id -match '^sha256:') -Message "Image $image did not have an immutable local image ID."
        Assert-Phase0 -Condition ($inspect.Size -gt 0) -Message "Image $image reported an empty size."
    }

    $defaultInspect = @((Get-NativeText -Executable $script:Docker -Arguments @('image', 'inspect', $defaultImage) -Operation 'Inspect default image') | ConvertFrom-Json)[0]
    Assert-Phase0 -Condition ($defaultInspect.Config.User -eq '10001:10001') -Message 'The default API image does not run as UID/GID 10001.'
    Assert-Phase0 -Condition ($defaultInspect.Config.Entrypoint -contains '/usr/local/bin/media-server-api') -Message 'The default image entrypoint is not the Rust API.'
    $defaultEnv = @($defaultInspect.Config.Env)
    Assert-Phase0 -Condition (-not ($defaultEnv | Where-Object { $_ -match '^(MEDIA_SERVER_DATABASE_URL|MEDIA_SERVER_SECRET|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET)=' })) -Message 'The default image config contains a runtime database or OAuth secret.'
    Assert-Phase0 -Condition (-not (($defaultEnv -join "`n") -match '(?i)D:\\Flicks|E:\\MediaServer')) -Message 'The default image environment contains a Windows production path.'

    $layerNames = @($defaultInspect.RootFS.Layers)
    $history = Get-NativeText -Executable $script:Docker -Arguments @('history', '--no-trunc', '--format', '{{.CreatedBy}}', $defaultImage) -Operation 'Inspect default image layer history'
    Assert-Phase0 -Condition ($history -notmatch '(?i)\.env|media\.db|D:\\Flicks|E:\\MediaServer|GOOGLE_CLIENT_SECRET|MEDIA_SERVER_SECRET=') -Message 'Default image layer history contains a prohibited path or credential reference.'
    $fsCheck = Get-NativeText -Executable $script:Docker -Arguments @('run', '--rm', '--entrypoint', '/bin/sh', $defaultImage, '-c', "test -x /usr/local/bin/media-server-api && test -d /app/web/dist && test ! -e /app/.env && test ! -e /app/media.db && test -d /media && test -d /cache && test -d /tmp && ! find /app -type f \( -name '.env' -o -name '.env.*' -o -name 'media.db' -o -name '*.mp4' -o -name '*.mkv' \) -print -quit | grep -q .") -Operation 'Inspect merged default image filesystem'
    Assert-Phase0 -Condition ($fsCheck -eq '') -Message 'The image filesystem scan returned unexpected output.'

    $buildResultName = if ($ReuseBuildCache) { 'Cached image build and image source inspection' } else { 'Cache-independent image build and image source inspection' }
    Write-Phase0Result -Name $buildResultName -State 'PASS' -Evidence ([pscustomobject]@{
        image = $defaultImage
        imageId = $defaultInspect.Id
        sizeBytes = [int64]$defaultInspect.Size
        layerCount = $layerNames.Count
        buildSeconds = [math]::Round($defaultBuildSeconds.Elapsed.TotalSeconds, 2)
        cacheMode = if ($ReuseBuildCache) { 'reused BuildKit layers; separate cold build passed in an earlier run' } else { 'no-cache' }
        user = $defaultInspect.Config.User
        sourceRevision = $script:SourceInfo.revision
        sourceSnapshotSha256 = $script:SourceInfo.snapshotSha256
        dockerContextFiles = $script:SourceInfo.contextFileCount
        dockerContextBytes = $script:SourceInfo.contextBytes
    })

    return [pscustomobject]@{
        DefaultImage = $defaultImage
        OAuthImage = $oauthImage
        MockImage = $mockImage
        DefaultInspect = $defaultInspect
    }
}

function Test-ComposeConfiguration {
    param([Parameter(Mandatory)][string]$Label)
    $configProject = "phase0-config-$($script:RunId)"
    $defaultPort = Get-FreeLoopbackPort
    $defaultEnvPath = Join-Path $script:TempRoot 'compose-default.env'
    Write-ComposeEnvironment -Path $defaultEnvPath -HttpPort $defaultPort -DatabasePassword '' -AppSecret '' -MediaPath ''
    $defaultPrefix = Get-ComposePrefix -Project $configProject -EnvironmentFile $defaultEnvPath
    $defaultConfig = Get-ComposeConfig -Prefix $defaultPrefix -Label "$Label defaults"

    $api = $defaultConfig.services.api
    $postgres = $defaultConfig.services.postgres
    $published = @($api.ports)
    $postgresPublished = @()
    if ($postgres.ContainsKey('ports')) { $postgresPublished = @($postgres['ports']) }
    Assert-Phase0 -Condition ($published.Count -eq 1 -and $published[0].host_ip -eq '127.0.0.1') -Message 'Compose must publish only the API on loopback.'
    Assert-Phase0 -Condition (@($postgresPublished).Count -eq 0) -Message 'Compose must not publish PostgreSQL to the host.'
    Assert-Phase0 -Condition ($postgres.environment.POSTGRES_PASSWORD -eq 'local-dev-only') -Message 'Compose development password default changed unexpectedly.'
    Assert-Phase0 -Condition ($api.environment.MEDIA_SERVER_SECRET -eq 'local-compose-only-change-before-exposure') -Message 'Compose development application-secret default changed unexpectedly.'
    Assert-Phase0 -Condition ($api.environment.MEDIA_SERVER_DATABASE_URL -match '@postgres:5432/') -Message 'Compose API does not target its private PostgreSQL service.'
    Assert-Phase0 -Condition ($api.environment.MEDIA_SERVER_DATABASE_URL -notmatch '(?i)127\.0\.0\.1|localhost|D:\\Flicks|E:\\MediaServer') -Message 'Compose database default includes a host production endpoint or media path.'
    $mediaVolume = @($api.volumes | Where-Object { $_.target -eq '/media' })[0]
    Assert-Phase0 -Condition ($mediaVolume.type -eq 'bind') -Message 'Compose media root is not an isolated bind mount.'
    $normalizedMedia = [System.IO.Path]::GetFullPath([string]$mediaVolume.source)
    Assert-Phase0 -Condition ($normalizedMedia.StartsWith($script:Snapshot, [System.StringComparison]::OrdinalIgnoreCase)) -Message 'Compose default media bind is outside the clean disposable source snapshot.'
    Assert-Phase0 -Condition ($normalizedMedia -match '(?i)[\\/]\.docker[\\/]local-data[\\/]media$') -Message 'Compose default media path is not .docker/local-data/media.'
    Assert-Phase0 -Condition ($api.environment.MEDIA_SERVER_MEDIA_ROOT -eq '/media' -and $api.environment.MEDIA_SERVER_CACHE_DIR -eq '/cache') -Message 'Compose media/cache container paths are not isolated Linux paths.'
    Assert-Phase0 -Condition (-not (($defaultConfig | ConvertTo-Json -Depth 40) -match '(?i)D:\\Flicks|E:\\MediaServer|media_server@127\.0\.0\.1')) -Message 'Compose defaults include a production path or database endpoint.'

    $overridePort = Get-FreeLoopbackPort
    $databasePassword = New-TestSecret
    $appSecret = New-TestSecret
    $overrideEnvPath = Join-Path $script:TempRoot 'compose-overrides.env'
    Write-ComposeEnvironment -Path $overrideEnvPath -HttpPort $overridePort -DatabasePassword $databasePassword -AppSecret $appSecret -MediaPath (Join-Path $script:TempRoot 'explicit-media')
    $overridePrefix = Get-ComposePrefix -Project $configProject -EnvironmentFile $overrideEnvPath
    $overrideConfig = Get-ComposeConfig -Prefix $overridePrefix -Label "$Label overrides"
    Assert-Phase0 -Condition ($overrideConfig.services.postgres.environment.POSTGRES_PASSWORD -eq $databasePassword) -Message 'Compose database password override was not applied.'
    Assert-Phase0 -Condition ($overrideConfig.services.api.environment.MEDIA_SERVER_SECRET -eq $appSecret) -Message 'Compose application-secret override was not applied.'
    Assert-Phase0 -Condition ($overrideConfig.services.api.environment.MEDIA_SERVER_MEDIA_ROOT -eq '/media') -Message 'Explicit media mount changed the in-container media root.'

    Write-Phase0Result -Name 'Compose defaults, loopback publication, private database, and secret overrides' -State 'PASS' -Evidence ([pscustomobject]@{
        defaultMediaPath = '.docker/local-data/media (resolved inside disposable source snapshot)'
        apiPublishedHostIp = $published[0].host_ip
        postgresPublishedPortCount = @($postgresPublished).Count
        databaseService = 'postgres'
        databaseSecretOverride = 'applied; value not recorded'
        applicationSecretOverride = 'applied; value not recorded'
    })
    return [pscustomobject]@{
        DefaultEnvironmentFile = $defaultEnvPath
        OverrideEnvironmentFile = $overrideEnvPath
        OverrideDatabasePassword = $databasePassword
        OverrideAppSecret = $appSecret
        OverridePort = $overridePort
    }
}

function ConvertFrom-HttpJson {
    param([Parameter(Mandatory)]$Response)
    try {
        return ConvertFrom-Phase0Json $Response.Content
    }
    catch {
        throw 'An API response was not valid JSON.'
    }
}

function Get-EncodedPathSegment {
    param([Parameter(Mandatory)][string]$Value)
    return [Uri]::EscapeDataString($Value)
}

function Get-ContainerId {
    param([Parameter(Mandatory)][string[]]$Prefix, [Parameter(Mandatory)][string]$Service)
    $id = Get-NativeText -Executable $script:Docker -Arguments ($Prefix + @('ps', '-q', $Service)) -Operation "Find $Service container"
    if (-not $id) {
        throw "Compose service $Service has no container."
    }
    return $id
}

function Get-RangeResponse {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Range,
        [Parameter()][string]$Cookie
    )
    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::Parse($Range)
    if ($Cookie) {
        $request.Headers.Add('Cookie', $Cookie)
    }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $contentRange = if ($response.Content.Headers.ContentRange) { [string]$response.Content.Headers.ContentRange } else { '' }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            ContentRange = $contentRange
            Bytes = $bytes
        }
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Get-HttpFile {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutputPath)
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 200) {
            [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers = @{ 'Content-Type' = [string]$response.Content.Headers.ContentType }
            Bytes = $bytes
        }
    }
    finally {
        $client.Dispose()
    }
}

function Wait-ForMovieName {
    param([Parameter(Mandatory)][string]$Origin, [Parameter(Mandatory)][string[]]$Names, [Parameter()][int]$TimeoutSeconds = 90)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $response = Invoke-Http -Uri "$Origin/api/movies" -Method GET
        if ([int]$response.StatusCode -eq 200) {
            $content = [string]$response.Content
            $allPresent = $true
            foreach ($name in $Names) {
                if (-not $content.Contains($name)) {
                    $allPresent = $false
                    break
                }
            }
            if ($allPresent) {
                return $response
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Disposable media fixtures were not visible in catalog results before timeout.'
}

function Start-TranscodeAndWait {
    param(
        [Parameter(Mandatory)][string]$Origin,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter()][string]$ContainerId,
        [Parameter()][string]$Quality = '360p',
        [Parameter()][int]$TimeoutSeconds = 240
    )
    $encoded = Get-EncodedPathSegment $Filename
    $start = Invoke-Http -Uri "$Origin/api/transcode/start/$encoded`?quality=$Quality" -Method POST -Body '{}' -ContentType 'application/json'
    Assert-Phase0 -Condition ([int]$start.StatusCode -eq 200) -Message "Transcode start did not return HTTP 200 for $Filename."
    $startBody = ConvertFrom-HttpJson $start
    Assert-Phase0 -Condition ($startBody.status -in @('queued', 'ready')) -Message "Transcode start returned an unexpected status for $Filename."
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $statuses = [System.Collections.Generic.List[string]]::new()
    $cpuSamples = [System.Collections.Generic.List[double]]::new()
    $nextCpuSample = [DateTimeOffset]::MinValue
    $last = $null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $statusResponse = Invoke-Http -Uri "$Origin/api/transcode-status/$encoded`?quality=$Quality" -Method GET
        if ([int]$statusResponse.StatusCode -ne 200) {
            Start-Sleep -Milliseconds 500
            continue
        }
        $last = ConvertFrom-HttpJson $statusResponse
        if ($last.status -and -not $statuses.Contains([string]$last.status)) {
            $statuses.Add([string]$last.status)
        }
        if ($ContainerId -and [DateTimeOffset]::UtcNow -ge $nextCpuSample) {
            $cpuText = Get-NativeText -Executable $script:Docker -Arguments @('stats', '--no-stream', '--format', '{{.CPUPerc}}', $ContainerId) -Operation "Measure CPU use during transcode of $Filename"
            $cpuMatch = [regex]::Match($cpuText, '([0-9]+(?:\.[0-9]+)?)%')
            if ($cpuMatch.Success) {
                $cpuSamples.Add([double]::Parse($cpuMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture))
            }
            $nextCpuSample = [DateTimeOffset]::UtcNow.AddSeconds(2)
        }
        if ($last.status -eq 'complete' -or $last.is_complete -eq $true) {
            break
        }
        if ($last.status -eq 'error' -or $last.status -eq 'failed') {
            throw "Transcode failed for $Filename."
        }
        Start-Sleep -Milliseconds 500
    }
    $watch.Stop()
    Assert-Phase0 -Condition ($last -and ($last.status -eq 'complete' -or $last.is_complete -eq $true)) -Message "Transcode did not complete within $TimeoutSeconds seconds for $Filename."
    Assert-Phase0 -Condition ([double]$last.progress -ge 99.9 -or [double]$last.percent -ge 99.9 -or $last.is_complete -eq $true) -Message "Transcode progress did not reach completion for $Filename."
    return [pscustomobject]@{
        StartStatus = [string]$startBody.status
        FinalStatus = [string]$last.status
        Progress = if ($null -ne $last.progress) { [double]$last.progress } else { [double]$last.percent }
        StatusesObserved = @($statuses)
        ElapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        CpuSampleCount = $cpuSamples.Count
        CpuAveragePercent = if ($cpuSamples.Count -gt 0) { [math]::Round(($cpuSamples | Measure-Object -Average).Average, 2) } else { $null }
        CpuPeakPercent = if ($cpuSamples.Count -gt 0) { [math]::Round(($cpuSamples | Measure-Object -Maximum).Maximum, 2) } else { $null }
    }
}

function Test-HlsOutputs {
    param(
        [Parameter(Mandatory)][string]$Origin,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$WorkDirectory
    )
    $encoded = Get-EncodedPathSegment $Filename
    $masterUri = "$Origin/hls/$encoded/master.m3u8"
    $master = Invoke-Http -Uri $masterUri -Method GET
    Assert-Phase0 -Condition ([int]$master.StatusCode -eq 200 -and $master.Content.StartsWith('#EXTM3U')) -Message 'HLS master playlist was not served successfully.'
    Assert-Phase0 -Condition ($master.Content.Contains('360p/playlist.m3u8')) -Message 'HLS master playlist does not advertise the 360p variant.'
    $variantUri = "$Origin/hls/$encoded/360p/playlist.m3u8"
    $variant = Invoke-Http -Uri $variantUri -Method GET
    Assert-Phase0 -Condition ([int]$variant.StatusCode -eq 200 -and $variant.Content.StartsWith('#EXTM3U')) -Message 'HLS variant playlist was not served successfully.'
    Assert-Phase0 -Condition ($variant.Content.Contains('#EXT-X-ENDLIST')) -Message 'HLS variant playlist was not sealed with ENDLIST.'

    $initMatch = [regex]::Match([string]$variant.Content, '#EXT-X-MAP:URI="([^"]+)"')
    Assert-Phase0 -Condition $initMatch.Success -Message 'HLS variant playlist is missing its fMP4 initialization map.'
    $initName = $initMatch.Groups[1].Value
    $initUri = "$Origin/hls/$encoded/360p/$initName"
    $initPath = Join-Path $WorkDirectory 'init-segment.bin'
    $initResponse = Get-HttpFile -Uri $initUri -OutputPath $initPath
    Assert-Phase0 -Condition ([int]$initResponse.StatusCode -eq 200 -and (Get-Item -LiteralPath $initPath).Length -gt 0) -Message 'HLS fMP4 initialization segment was not served.'

    $segmentName = ([string]$variant.Content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^segment_.*\.(m4s|ts)$' } | Select-Object -First 1)
    Assert-Phase0 -Condition ([bool]$segmentName) -Message 'HLS variant playlist did not name a media segment.'
    $segmentPath = Join-Path $WorkDirectory 'media-segment.bin'
    $segmentResponse = Get-HttpFile -Uri "$Origin/hls/$encoded/360p/$segmentName" -OutputPath $segmentPath
    Assert-Phase0 -Condition ([int]$segmentResponse.StatusCode -eq 200 -and (Get-Item -LiteralPath $segmentPath).Length -gt 0) -Message 'HLS media segment was not served.'

    $durations = [regex]::Matches([string]$variant.Content, '#EXTINF:([0-9]+(?:\.[0-9]+)?)')
    $coverage = 0.0
    foreach ($match in $durations) {
        $coverage += [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
    $sourceDurationText = Get-NativeText -Executable $ffprobe -Arguments @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', $SourcePath) -Operation 'Measure disposable source container duration'
    $sourceDuration = [double]::Parse(($sourceDurationText -split "`n" | Select-Object -First 1), [Globalization.CultureInfo]::InvariantCulture)
    Assert-Phase0 -Condition ($durations.Count -gt 0 -and $sourceDuration -gt 0 -and $coverage -ge ($sourceDuration * 0.98)) -Message 'HLS playlist segment durations do not cover at least 98% of the source video.'

    return [pscustomobject]@{
        masterStatus = [int]$master.StatusCode
        variantStatus = [int]$variant.StatusCode
        initStatus = [int]$initResponse.StatusCode
        segmentStatus = [int]$segmentResponse.StatusCode
        segmentCount = $durations.Count
        sourceDurationSeconds = [math]::Round($sourceDuration, 3)
        playlistCoverageSeconds = [math]::Round($coverage, 3)
        initBytes = (Get-Item -LiteralPath $initPath).Length
        segmentBytes = (Get-Item -LiteralPath $segmentPath).Length
    }
}

function Test-OAuthDisabledAndProductionTarget {
    param([Parameter(Mandatory)][string]$Image)
    $project = "phase0-oauth-default-$($script:RunId)"
    $port = Get-FreeLoopbackPort
    $dbPassword = New-TestSecret
    $appSecret = New-TestSecret
    $testClientId = "phase0-default-$($script:RunId)"
    $testClientSecret = New-TestSecret
    $envPath = Join-Path $script:TempRoot 'compose-default-runtime.env'
    $emptyMediaPath = ''
    Write-ComposeEnvironment -Path $envPath -HttpPort $port -DatabasePassword $dbPassword -AppSecret $appSecret -MediaPath $emptyMediaPath
    $overridePath = Join-Path $script:TempRoot 'compose-default-image.override.yaml'
    Write-ComposeImageOverride -Path $overridePath -Image $Image
    $prefix = Get-ComposePrefix -Project $project -EnvironmentFile $envPath -OverrideFile $overridePath
    $script:ComposeProjects.Add([pscustomobject]@{ Name = $project; EnvironmentFile = $envPath; OverrideFile = $overridePath })
    $origin = "http://127.0.0.1:$port"

    $startup = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-build')) -Operation 'Start isolated default Compose project' -LogPath (Join-Path $script:Logs 'compose-default-up.log')
    $apiId = Wait-ForApiContainer -Prefix $prefix -Origin $origin
    $startup.Stop()

    $disabled = Invoke-Http -Uri "$origin/auth/google" -Method GET
    Assert-Phase0 -Condition ([int]$disabled.StatusCode -eq 307) -Message 'Disabled OAuth did not return the documented account redirect.'
    Assert-Phase0 -Condition ([string]$disabled.Headers['Location'] -eq '/account?error=oauth_unconfigured') -Message 'Disabled OAuth redirect changed unexpectedly.'

    Write-ComposeEnvironment -Path $envPath -HttpPort $port -DatabasePassword $dbPassword -AppSecret $appSecret -MediaPath $emptyMediaPath -GoogleClientId $testClientId -GoogleClientSecret $testClientSecret
    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-deps', '--force-recreate', '--no-build', 'api')) -Operation 'Recreate default-image API with disposable OAuth settings' -LogPath (Join-Path $script:Logs 'compose-default-recreate.log')
    $apiId = Wait-ForApiContainer -Prefix $prefix -Origin $origin
    $enabled = Invoke-Http -Uri "$origin/auth/google" -Method GET
    $enabledLocation = [string]$enabled.Headers['Location']
    Assert-Phase0 -Condition ([int]$enabled.StatusCode -eq 307 -and $enabledLocation.StartsWith('https://accounts.google.com/o/oauth2/v2/auth')) -Message 'The default image did not retain Google HTTPS OAuth endpoints.'

    $pgId = Get-ContainerId -Prefix $prefix -Service 'postgres'
    $published = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{json .NetworkSettings.Ports}}', $pgId) -Operation 'Inspect default Compose PostgreSQL port publication' | ConvertFrom-Json
    Assert-Phase0 -Condition (-not $published.'5432/tcp') -Message 'Compose PostgreSQL unexpectedly has a host port binding.'
    $apiUid = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'id', '-u') -Operation 'Read default API UID'
    $apiGid = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'id', '-g') -Operation 'Read default API GID'
    Assert-Phase0 -Condition ($apiUid -eq '10001' -and $apiGid -eq '10001') -Message 'Default Compose API did not run as UID/GID 10001.'
    $logs = Get-NativeText -Executable $script:Docker -Arguments ($prefix + @('logs', '--no-color')) -Operation 'Read default Compose logs'
    foreach ($secret in @($dbPassword, $appSecret, $testClientSecret)) {
        Assert-Phase0 -Condition (-not $logs.Contains($secret)) -Message 'A disposable database, application, or OAuth credential appeared in Compose logs.'
    }

    Write-Phase0Result -Name 'Default image OAuth disabled/enabled configuration and private PostgreSQL' -State 'PASS' -Evidence ([pscustomobject]@{
        oauthDisabledStatus = [int]$disabled.StatusCode
        oauthEnabledStatus = [int]$enabled.StatusCode
        oauthTargetHost = 'accounts.google.com over HTTPS'
        databaseHostPortPublished = $false
        apiUid = $apiUid
        apiGid = $apiGid
        initialStartupSeconds = [math]::Round($startup.Elapsed.TotalSeconds, 2)
        logCredentialLeaks = 0
    })

    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('down', '--volumes', '--remove-orphans')) -Operation 'Remove isolated default Compose resources' -LogPath (Join-Path $script:Logs 'compose-default-down.log')
}

function Test-ComposeEndToEnd {
    param(
        [Parameter(Mandatory)][string]$ApiImage,
        [Parameter(Mandatory)][string]$MockImage
    )
    $project = "phase0-e2e-$($script:RunId)"
    $port = Get-FreeLoopbackPort
    $origin = "http://127.0.0.1:$port"
    $mediaRoot = Join-Path $script:TempRoot 'compose-media'
    $workDirectory = Join-Path $script:TempRoot 'compose-artifacts'
    New-Item -ItemType Directory -Path $mediaRoot, $workDirectory -Force | Out-Null

    $srtContent = "1`n00:00:00,000 --> 00:00:05,000`nDisposable Phase 0 subtitle.`n"
    $srtPath = Join-Path $mediaRoot 'Phase0Hls.en.srt'
    Write-PrivateText -Path $srtPath -Text $srtContent
    $directPath = Join-Path $mediaRoot 'Phase0Direct.mp4'
    $hlsPath = Join-Path $mediaRoot 'Phase0Hls.mkv'
    New-SyntheticMedia -Path $directPath -Duration '4' -Size '320x180'
    New-SyntheticMedia -Path $hlsPath -Duration '12' -Size '320x180' -SubtitlePath $srtPath
    $dbPassword = New-TestSecret
    $appSecret = New-TestSecret
    $oauthClientId = "phase0-$($script:RunId)"
    $oauthClientSecret = New-TestSecret
    $envPath = Join-Path $script:TempRoot 'compose-e2e.env'
    Write-ComposeEnvironment -Path $envPath -HttpPort $port -DatabasePassword $dbPassword -AppSecret $appSecret -MediaPath $mediaRoot -GoogleClientId $oauthClientId -GoogleClientSecret $oauthClientSecret
    $overridePath = Join-Path $script:TempRoot 'compose-e2e.override.yaml'
    Write-ComposeOAuthOverride -Path $overridePath -ApiImage $ApiImage -MockImage $MockImage
    $prefix = Get-ComposePrefix -Project $project -EnvironmentFile $envPath -OverrideFile $overridePath
    $script:ComposeProjects.Add([pscustomobject]@{ Name = $project; EnvironmentFile = $envPath; OverrideFile = $overridePath })

    $resolvedConfig = Get-ComposeConfig -Prefix $prefix -Label 'isolated end-to-end'
    $e2ePostgres = $resolvedConfig.services.postgres
    $e2ePostgresPorts = @()
    if ($e2ePostgres.ContainsKey('ports')) { $e2ePostgresPorts = @($e2ePostgres['ports']) }
    Assert-Phase0 -Condition (@($e2ePostgresPorts).Count -eq 0) -Message 'The end-to-end Compose configuration publishes PostgreSQL.'
    $configuredGracePeriod = [string]$resolvedConfig.services.api.stop_grace_period
    Assert-Phase0 -Condition ($configuredGracePeriod -match '^(240s|4m0?s?|00:04:00|PT4M)$') -Message 'Compose API stop grace period is not configured as four minutes.'
    Assert-Phase0 -Condition ($resolvedConfig.services.api.ports[0].host_ip -eq '127.0.0.1') -Message 'The end-to-end Compose API is not loopback-only.'
    $configuredMedia = @($resolvedConfig.services.api.volumes | Where-Object { $_.target -eq '/media' })[0].source
    Assert-Phase0 -Condition ([System.IO.Path]::GetFullPath([string]$configuredMedia) -eq [System.IO.Path]::GetFullPath($mediaRoot)) -Message 'The end-to-end Compose media root does not point at its disposable fixture directory.'

    $startup = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-build')) -Operation 'Start isolated Compose end-to-end project' -LogPath (Join-Path $script:Logs 'compose-e2e-up.log')
    Wait-ComposeHealthy -Prefix $prefix -Services @('postgres', 'api', 'phase0-oauth-mock')
    $startup.Stop()
    $apiId = Get-ContainerId -Prefix $prefix -Service 'api'
    $pgId = Get-ContainerId -Prefix $prefix -Service 'postgres'

    $health = Wait-HttpStatus -Uri "$origin/health" -ExpectedStatus 200
    $spa = Invoke-Http -Uri "$origin/" -Method GET
    Assert-Phase0 -Condition ([int]$spa.StatusCode -eq 200 -and $spa.Headers['Content-Type'] -like 'text/html*') -Message 'The React SPA did not respond successfully.'
    $moviesResponse = Invoke-Http -Uri "$origin/api/movies" -Method GET
    Assert-Phase0 -Condition ([int]$moviesResponse.StatusCode -eq 200) -Message 'The API could not read its own PostgreSQL database.'

    $uid = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'id', '-u') -Operation 'Read Compose API UID'
    $gid = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'id', '-g') -Operation 'Read Compose API GID'
    Assert-Phase0 -Condition ($uid -eq '10001' -and $gid -eq '10001') -Message 'Compose API runtime identity is not UID/GID 10001.'
    $writeCheck = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'sh', '-c', 'for d in /media /cache /tmp; do f="$d/.phase0-write-check"; touch "$f" && rm -f "$f" || exit 1; done') -Operation 'Verify writable Compose mounts'
    $apiMounts = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{json .Mounts}}', $apiId) -Operation 'Inspect Compose API mounts' | ConvertFrom-Json
    foreach ($target in @('/media', '/cache')) {
        Assert-Phase0 -Condition (@($apiMounts | Where-Object { $_.Destination -eq $target }).Count -gt 0) -Message "Compose API is missing the $target mount."
    }
    $mediaMountMatch = @($apiMounts | Where-Object { $_.Destination -eq '/media' -and $_.Type -eq 'bind' -and $_.RW -eq $true })
    Assert-Phase0 -Condition ($mediaMountMatch.Count -eq 1) -Message 'Compose API does not have a writable media bind mount.'
    $publishedDb = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{json .NetworkSettings.Ports}}', $pgId) -Operation 'Inspect Compose database port publication' | ConvertFrom-Json
    Assert-Phase0 -Condition (-not $publishedDb.'5432/tcp') -Message 'Compose PostgreSQL has a public host port.'

    $unauthorizedUpload = Invoke-Http -Uri "$origin/api/upload/chunk/init" -Method POST -Body (@{ filename = 'denied.mp4'; size = 4 } | ConvertTo-Json -Compress)
    Assert-Phase0 -Condition ([int]$unauthorizedUpload.StatusCode -eq 403) -Message 'Anonymous upload initialization was not denied.'
    $unauthorizedScan = Invoke-Http -Uri "$origin/api/scan" -Method POST -Body '{}'
    Assert-Phase0 -Condition ([int]$unauthorizedScan.StatusCode -eq 403) -Message 'Anonymous admin scan action was not denied.'

    $adminCallback = Wait-ForOAuthCallbackCookie -Origin $origin -Code 'phase0-admin-code'
    $adminCookie = Get-SessionCookie $adminCallback
    $adminIdentity = Invoke-Http -Uri "$origin/api/auth/me" -Method GET -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$adminIdentity.StatusCode -eq 200 -and $adminIdentity.Content -match 'phase0-admin@example\.test') -Message 'The allowed OAuth admin sign-in did not create an authenticated session.'
    $viewerCallback = Wait-ForOAuthCallbackCookie -Origin $origin -Code 'phase0-viewer-code'
    $viewerCookie = Get-SessionCookie $viewerCallback
    $viewerDenied = Invoke-Http -Uri "$origin/api/upload/chunk/init" -Method POST -Headers @{ Cookie = $viewerCookie } -Body (@{ filename = 'viewer-denied.mp4'; size = 4 } | ConvertTo-Json -Compress)
    Assert-Phase0 -Condition ([int]$viewerDenied.StatusCode -eq 403) -Message 'An authenticated viewer was allowed to upload.'
    $deniedStart = Invoke-Http -Uri "$origin/auth/google" -Method GET
    $deniedState = $null
    foreach ($pair in ([Uri]([string]$deniedStart.Headers['Location'])).Query.TrimStart('?').Split('&')) {
        $parts = $pair.Split('=', 2)
        if ($parts.Count -eq 2 -and $parts[0] -eq 'state') { $deniedState = [Uri]::UnescapeDataString($parts[1]); break }
    }
    Assert-Phase0 -Condition ([bool]$deniedState) -Message 'Could not start the denied OAuth test attempt.'
    $deniedCallback = Invoke-Http -Uri "$origin/auth/google/callback?code=phase0-denied-code&state=$([Uri]::EscapeDataString($deniedState))" -Method GET
    Assert-Phase0 -Condition ([int]$deniedCallback.StatusCode -eq 403 -and -not $deniedCallback.Headers['Set-Cookie']) -Message 'OAuth sign-in for an account outside the allowlist was not denied.'

    $scan = Invoke-Http -Uri "$origin/api/scan" -Method POST -Headers @{ Cookie = $adminCookie } -Body '{}'
    Assert-Phase0 -Condition ([int]$scan.StatusCode -eq 200) -Message 'Authenticated scan action failed.'
    $catalog = Wait-ForMovieName -Origin $origin -Names @('Phase0Direct.mp4', 'Phase0Hls.mkv')
    $probeLog = Join-Path $script:Logs 'android-api-contract-probe.log'
    Invoke-Logged -Executable 'python' -Arguments @((Join-Path $script:Snapshot 'scripts/probe_android_api.py'), '--base', $origin) -Operation 'Probe shipped Android API contract against isolated Compose service' -LogPath $probeLog
    $probeSummary = Get-Content -LiteralPath $probeLog | Where-Object { $_ -match '^RESULT:' } | Select-Object -Last 1
    Assert-Phase0 -Condition ($probeSummary -match 'all \d+ Android client endpoints respond per contract') -Message 'The Android API contract probe did not report a complete successful endpoint sweep.'
    Write-Phase0Result -Name 'Flutter Android API contract probe against disposable Compose service' -State 'PASS' -Evidence ([pscustomobject]@{ summary = $probeSummary })

    $directLength = (Get-Item -LiteralPath $directPath).Length
    $directUri = "$origin/media/$(Get-EncodedPathSegment 'Phase0Direct.mp4')"
    $normalRange = Get-RangeResponse -Uri $directUri -Range 'bytes=0-1023'
    Assert-Phase0 -Condition ($normalRange.StatusCode -eq 206 -and $normalRange.Bytes.Length -eq 1024 -and $normalRange.ContentRange -eq "bytes 0-1023/$directLength") -Message 'Direct-play normal byte range failed.'
    $boundaryRange = Get-RangeResponse -Uri $directUri -Range "bytes=$($directLength - 1)-$($directLength - 1)"
    Assert-Phase0 -Condition ($boundaryRange.StatusCode -eq 206 -and $boundaryRange.Bytes.Length -eq 1 -and $boundaryRange.ContentRange -eq "bytes $($directLength - 1)-$($directLength - 1)/$directLength") -Message 'Direct-play final-byte boundary range failed.'
    $invalidRange = Get-RangeResponse -Uri $directUri -Range "bytes=$directLength-"
    Assert-Phase0 -Condition ($invalidRange.StatusCode -eq 416 -and $invalidRange.ContentRange -eq "bytes */$directLength") -Message 'Unsatisfiable direct-play range did not return HTTP 416.'

    $hlsResult = Start-TranscodeAndWait -Origin $origin -Filename 'Phase0Hls.mkv' -ContainerId $apiId -Quality '360p'
    $hlsOutputs = Test-HlsOutputs -Origin $origin -Filename 'Phase0Hls.mkv' -SourcePath $hlsPath -WorkDirectory $workDirectory

    $subtitleResponse = Invoke-Http -Uri "$origin/api/subtitles/$(Get-EncodedPathSegment 'Phase0Hls.mkv')" -Method GET
    Assert-Phase0 -Condition ([int]$subtitleResponse.StatusCode -eq 200) -Message 'Subtitle listing endpoint failed.'
    $subtitleList = ConvertFrom-HttpJson $subtitleResponse
    $sidecarTrack = @($subtitleList.tracks | Where-Object { $_.src -match '\.en\.srt$' -or $_.src -match 'Phase0Hls\.en' } | Select-Object -First 1)
    Assert-Phase0 -Condition ($sidecarTrack.Count -gt 0) -Message 'The disposable sidecar subtitle was not listed.'
    $sidecarVtt = Invoke-Http -Uri "$origin$($sidecarTrack[0].src)" -Method GET
    Assert-Phase0 -Condition ([int]$sidecarVtt.StatusCode -eq 200 -and $sidecarVtt.Content.StartsWith('WEBVTT')) -Message 'Sidecar subtitle was not delivered as WebVTT.'
    $embeddedTrack = @($subtitleList.tracks | Where-Object { $_.src -match '^/subtitles/embedded/' } | Select-Object -First 1)
    Assert-Phase0 -Condition ($embeddedTrack.Count -gt 0) -Message 'The deterministic embedded subtitle was not listed.'
    $embeddedVtt = Invoke-Http -Uri "$origin$($embeddedTrack[0].src)" -Method GET
    Assert-Phase0 -Condition ([int]$embeddedVtt.StatusCode -eq 200 -and $embeddedVtt.Content.StartsWith('WEBVTT')) -Message 'Embedded subtitle was not delivered as WebVTT.'

    $previewMeta = Invoke-Http -Uri "$origin/api/seek-preview-meta/$(Get-EncodedPathSegment 'Phase0Hls.mkv')" -Method GET
    Assert-Phase0 -Condition ([int]$previewMeta.StatusCode -eq 200) -Message 'Seek-preview metadata request failed.'
    $preview = ConvertFrom-HttpJson $previewMeta
    Assert-Phase0 -Condition ([double]$preview.duration -gt 0 -and [int]$preview.count -gt 0 -and $preview.base_url) -Message 'Seek-preview metadata was incomplete.'
    $previewPath = "$($preview.base_url.TrimEnd('/'))/thumb_00000.jpg"
    $previewFile = Join-Path $workDirectory 'preview.jpg'
    $previewResponse = Get-HttpFile -Uri "$origin$previewPath" -OutputPath $previewFile
    Assert-Phase0 -Condition ([int]$previewResponse.StatusCode -eq 200 -and $previewResponse.Headers['Content-Type'] -like 'image/jpeg*' -and (Get-Item -LiteralPath $previewFile).Length -gt 100) -Message 'Seek-preview thumbnail was not generated and served.'

    $uploadBytes = [System.IO.File]::ReadAllBytes($hlsPath)
    Assert-Phase0 -Condition ($uploadBytes.Length -lt (8 * 1024 * 1024)) -Message 'The deterministic upload fixture exceeds the single-chunk test size.'
    $uploadInitResponse = Invoke-Http -Uri "$origin/api/upload/chunk/init" -Method POST -Headers @{ Cookie = $adminCookie } -Body (@{ filename = 'phase0-upload-source.mkv'; size = $uploadBytes.Length; title = 'Phase0Uploaded' } | ConvertTo-Json -Compress)
    Assert-Phase0 -Condition ([int]$uploadInitResponse.StatusCode -eq 200) -Message 'Authenticated upload initialization failed.'
    $uploadInit = ConvertFrom-HttpJson $uploadInitResponse
    $uploadId = [string]$uploadInit.upload_id
    Assert-Phase0 -Condition ($uploadId -match '^[A-Za-z0-9_-]+$') -Message 'Upload initialization returned an invalid upload ID.'
    $chunkResponse = Invoke-Http -Uri "$origin/api/upload/chunk/$uploadId" -Method POST -Headers @{ Cookie = $adminCookie; 'X-Upload-Offset' = '0' } -Body $uploadBytes -ContentType 'application/octet-stream'
    Assert-Phase0 -Condition ([int]$chunkResponse.StatusCode -eq 200) -Message 'Authenticated upload chunk failed.'
    $completeResponse = Invoke-Http -Uri "$origin/api/upload/chunk/$uploadId/complete" -Method POST -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$completeResponse.StatusCode -eq 200) -Message 'Authenticated upload completion failed.'
    $uploadComplete = ConvertFrom-HttpJson $completeResponse
    $uploadedFilename = [string]$uploadComplete.filename
    Assert-Phase0 -Condition ($uploadedFilename -eq 'Phase0Uploaded.mkv' -and $uploadComplete.success -eq $true) -Message 'Upload completion returned an unexpected catalog filename.'
    Assert-Phase0 -Condition (Test-Path -LiteralPath (Join-Path $mediaRoot $uploadedFilename)) -Message 'Completed upload file was not written to the media volume.'

    $abortInit = Invoke-Http -Uri "$origin/api/upload/chunk/init" -Method POST -Headers @{ Cookie = $adminCookie } -Body (@{ filename = 'phase0-abort.mkv'; size = 8 } | ConvertTo-Json -Compress)
    Assert-Phase0 -Condition ([int]$abortInit.StatusCode -eq 200) -Message 'Authenticated abort-flow initialization failed.'
    $abortId = [string](ConvertFrom-HttpJson $abortInit).upload_id
    $partial = [byte[]]@(1, 2, 3, 4)
    $partialResponse = Invoke-Http -Uri "$origin/api/upload/chunk/$abortId" -Method POST -Headers @{ Cookie = $adminCookie; 'X-Upload-Offset' = '0' } -Body $partial -ContentType 'application/octet-stream'
    Assert-Phase0 -Condition ([int]$partialResponse.StatusCode -eq 200) -Message 'Abort-flow partial upload failed.'
    $abortResponse = Invoke-Http -Uri "$origin/api/upload/chunk/$abortId" -Method DELETE -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$abortResponse.StatusCode -eq 200) -Message 'Authenticated upload abort failed.'
    $abortCleanup = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'sh', '-c', "test ! -e '/media/.uploads/$abortId.part' && test ! -e '/media/.uploads/$abortId.json'") -Operation 'Verify aborted upload temporary-file cleanup'

    $uploadedCatalog = Wait-ForMovieName -Origin $origin -Names @($uploadedFilename)
    $unauthorizedArchive = Invoke-Http -Uri "$origin/api/storage/archive/$(Get-EncodedPathSegment $uploadedFilename)" -Method POST
    Assert-Phase0 -Condition ([int]$unauthorizedArchive.StatusCode -eq 403) -Message 'Anonymous archive action was not denied.'
    $viewerArchive = Invoke-Http -Uri "$origin/api/storage/archive/$(Get-EncodedPathSegment $uploadedFilename)" -Method POST -Headers @{ Cookie = $viewerCookie }
    Assert-Phase0 -Condition ([int]$viewerArchive.StatusCode -eq 403) -Message 'Viewer archive action was not denied.'
    $uploadTranscode = Start-TranscodeAndWait -Origin $origin -Filename $uploadedFilename -ContainerId $apiId -Quality '360p'
    $archiveResponse = Invoke-Http -Uri "$origin/api/storage/archive/$(Get-EncodedPathSegment $uploadedFilename)" -Method POST -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$archiveResponse.StatusCode -eq 200) -Message 'Authenticated admin could not archive fully transcoded uploaded media.'
    $archivedPath = Join-Path (Join-Path $mediaRoot '.archive') $uploadedFilename
    Assert-Phase0 -Condition ((Test-Path -LiteralPath $archivedPath) -and -not (Test-Path -LiteralPath (Join-Path $mediaRoot $uploadedFilename))) -Message 'Archive did not move the completed upload into the isolated archive directory.'

    $marker = "phase0-$($script:RunId)"
    $markerSql = "CREATE TABLE IF NOT EXISTS phase0_persistence_markers (marker text PRIMARY KEY); INSERT INTO phase0_persistence_markers(marker) VALUES ('$marker') ON CONFLICT (marker) DO NOTHING;"
    $null = Get-NativeText -Executable $script:Docker -Arguments @('exec', $pgId, 'psql', '-U', 'media_server', '-d', 'media_server', '-v', 'ON_ERROR_STOP=1', '-c', $markerSql) -Operation 'Insert disposable Compose persistence marker'
    $beforeRestart = Invoke-Http -Uri "$origin/api/movies" -Method GET
    Assert-Phase0 -Condition ([int]$beforeRestart.StatusCode -eq 200) -Message 'API database read failed before recreation.'
    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-deps', '--force-recreate', '--no-build', 'api')) -Operation 'Recreate isolated Compose API' -LogPath (Join-Path $script:Logs 'compose-api-recreate.log')
    $apiId = Wait-ForApiContainer -Prefix $prefix -Origin $origin
    $afterApiRestart = Invoke-Http -Uri "$origin/api/movies" -Method GET
    Assert-Phase0 -Condition ([int]$afterApiRestart.StatusCode -eq 200) -Message 'API failed to reconnect to its Compose PostgreSQL database after recreation.'
    Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-deps', '--force-recreate', 'postgres')) -Operation 'Recreate isolated Compose PostgreSQL container' -LogPath (Join-Path $script:Logs 'compose-postgres-recreate.log')
    Wait-ComposeHealthy -Prefix $prefix -Services @('postgres')
    $pgId = Get-ContainerId -Prefix $prefix -Service 'postgres'
    $markerCount = Get-NativeText -Executable $script:Docker -Arguments @('exec', $pgId, 'psql', '-U', 'media_server', '-d', 'media_server', '-tAc', "SELECT count(*) FROM phase0_persistence_markers WHERE marker = '$marker'") -Operation 'Verify Compose marker after PostgreSQL recreation'
    Assert-Phase0 -Condition ($markerCount.Trim() -eq '1') -Message 'Compose PostgreSQL data did not survive database-container recreation.'
    $afterDbRestart = Invoke-Http -Uri "$origin/api/movies" -Method GET
    Assert-Phase0 -Condition ([int]$afterDbRestart.StatusCode -eq 200) -Message 'API did not reconnect after PostgreSQL container recreation.'

    $shutdownRuns = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $ComposeShutdownRepetitions; $i++) {
        $shutdownName = "Phase0Shutdown-$i.mkv"
        # Create after the initial library scan so the boot-time sweeper cannot
        # race the regression by retrying the previously interrupted fixture.
        $shutdownDuration = [string](180 + ($i * 11))
        New-SyntheticMedia -Path (Join-Path $mediaRoot $shutdownName) -Duration $shutdownDuration -Size '640x360'
        $shutdownEncoded = Get-EncodedPathSegment $shutdownName
        $shutdownStart = Invoke-Http -Uri "$origin/api/transcode/start/$shutdownEncoded`?quality=360p" -Method POST -Body '{}' -ContentType 'application/json'
        Assert-Phase0 -Condition ([int]$shutdownStart.StatusCode -eq 200) -Message "Could not start shutdown transcode repetition $i."

        $processDeadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
        $activeFfmpeg = ''
        while ([DateTimeOffset]::UtcNow -lt $processDeadline) {
            $activeFfmpeg = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'sh', '-c', "ps -eo args | grep '[f]fmpeg' | grep -F '$shutdownName' || true") -Operation "Find active FFmpeg process for shutdown repetition $i"
            if ($activeFfmpeg) { break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $activeFfmpeg) {
            $statusDiagnostic = Invoke-Http -Uri "$origin/api/transcode-status/$shutdownEncoded`?quality=360p" -Method GET
            $processDiagnostic = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'sh', '-c', "ps -eo args | grep '[f]fmpeg' || true") -Operation "Collect active FFmpeg diagnostics for shutdown repetition $i"
            throw "Shutdown repetition $i never observed its active FFmpeg child process. Start response: $($shutdownStart.Content); status HTTP $($statusDiagnostic.StatusCode): $($statusDiagnostic.Content); FFmpeg process list: $processDiagnostic"
        }

        $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('stop', '--timeout', '240', 'api')) -Operation "Gracefully stop Compose API during active FFmpeg repetition $i" -LogPath (Join-Path $script:Logs "compose-shutdown-$i.log")
        Wait-ContainerStopped -ContainerId $apiId -TimeoutSeconds 245
        $stopWatch.Stop()
        $containerState = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{.State.ExitCode}}|{{.State.OOMKilled}}', $apiId) -Operation "Inspect stopped Compose API repetition $i"
        Assert-Phase0 -Condition ($containerState -eq '0|false') -Message "Compose API did not exit cleanly during shutdown repetition $i."
        $shutdownRuns.Add([pscustomobject]@{
            repetition = $i
            activeFfmpegObserved = $true
            containerExitCode = 0
            oomKilled = $false
            seconds = [math]::Round($stopWatch.Elapsed.TotalSeconds, 2)
        })

        Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('up', '-d', '--no-deps', 'api')) -Operation "Restart Compose API after shutdown repetition $i" -LogPath (Join-Path $script:Logs "compose-restart-$i.log")
        $apiId = Wait-ForApiContainer -Prefix $prefix -Origin $origin
        $jobStatusSql = "SELECT status FROM transcode_jobs WHERE filename = '$shutdownName' AND mode = 'hls:360p'"
        $interruptedStatus = Get-NativeText -Executable $script:Docker -Arguments @('exec', $pgId, 'psql', '-U', 'media_server', '-d', 'media_server', '-tAc', $jobStatusSql) -Operation "Read interrupted job state after Compose API restart $i"
        Assert-Phase0 -Condition ($interruptedStatus.Trim() -eq 'failed') -Message "Interrupted Compose transcode job $shutdownName did not reconcile to failed after API restart."
        $orphanFfmpeg = Get-NativeText -Executable $script:Docker -Arguments @('exec', $apiId, 'sh', '-c', "ps -eo args | grep '[f]fmpeg' | grep -F '$shutdownName' || true") -Operation "Check Compose FFmpeg cleanup after shutdown repetition $i"
        Assert-Phase0 -Condition (-not $orphanFfmpeg) -Message "FFmpeg child for $shutdownName remained active after Compose API restart."
        $shutdownRuns[$shutdownRuns.Count - 1] | Add-Member -NotePropertyName interruptedJobStatus -NotePropertyValue $interruptedStatus.Trim()
        $shutdownRuns[$shutdownRuns.Count - 1] | Add-Member -NotePropertyName orphanFfmpegAfterRestart -NotePropertyValue $false
    }

    $secretLogs = Get-NativeText -Executable $script:Docker -Arguments ($prefix + @('logs', '--no-color')) -Operation 'Read isolated Compose logs for credential scan'
    foreach ($secret in @($dbPassword, $appSecret, $oauthClientSecret)) {
        Assert-Phase0 -Condition (-not $secretLogs.Contains($secret)) -Message 'A disposable credential appeared in the end-to-end Compose logs.'
    }

    Write-Phase0Result -Name 'Compose application paths, API E2E, auth, media pipeline, uploads, and persistence' -State 'PASS' -Evidence ([pscustomobject]@{
        startupSeconds = [math]::Round($startup.Elapsed.TotalSeconds, 2)
        apiUid = $uid
        apiGid = $gid
        apiHealthStatus = [int]$health.StatusCode
        spaStatus = [int]$spa.StatusCode
        scanCatalogContainsFixtures = $true
        directPlayNormalRangeStatus = $normalRange.StatusCode
        directPlayBoundaryRangeStatus = $boundaryRange.StatusCode
        directPlayUnsatisfiableStatus = $invalidRange.StatusCode
        hls = $hlsOutputs
        hlsTranscode = $hlsResult
        uploadTranscode = $uploadTranscode
        subtitles = [pscustomobject]@{ sidecar = [int]$sidecarVtt.StatusCode; embedded = [int]$embeddedVtt.StatusCode }
        preview = [pscustomobject]@{ metadata = [int]$previewMeta.StatusCode; thumbnail = [int]$previewResponse.StatusCode; thumbnailBytes = (Get-Item -LiteralPath $previewFile).Length }
        uploadCompletion = [int]$completeResponse.StatusCode
        abortCleanup = $true
        archive = [int]$archiveResponse.StatusCode
        postgresqlRecreationMarkerCount = [int]$markerCount.Trim()
        composeShutdownGraceSeconds = 240
        composeActiveFfmpegShutdown = @($shutdownRuns)
        logCredentialLeaks = 0
    })

    return [pscustomobject]@{
        Prefix = $prefix
        Origin = $origin
        ApiId = $apiId
        PgId = $pgId
        MediaRoot = $mediaRoot
        DatabasePassword = $dbPassword
        AppSecret = $appSecret
        OAuthClientSecret = $oauthClientSecret
    }
}

function Get-ProtectedLocalBaseline {
    $context = Invoke-KubectlText -Arguments @('config', 'current-context') -Operation 'Read selected Kubernetes context'
    Assert-Phase0 -Condition ($context -eq 'docker-desktop') -Message 'Phase 0 Kubernetes checks require the already-configured local docker-desktop context.'
    $config = Invoke-KubectlText -Arguments @('config', 'view', '--minify', '-o', 'json') -Operation 'Inspect selected Kubernetes API endpoint' | ConvertFrom-Json
    $server = [string]$config.clusters[0].cluster.server
    Assert-Phase0 -Condition ([Uri]$server -and ([Uri]$server).IsLoopback) -Message 'The active Kubernetes context does not point to a loopback-only local cluster.'

    $protectedNamespace = Invoke-KubectlText -Arguments @('get', 'namespace', 'media-server', '-o', 'json') -Operation 'Inspect existing protected media-server namespace' | ConvertFrom-Json
    $protectedRelease = Invoke-DockerText -Arguments @('ps', '-q', '--filter', 'label=com.docker.compose.project=mediaserver') -Operation 'Inspect existing protected Compose project'
    Assert-Phase0 -Condition ([bool]$protectedNamespace.metadata.uid -and [bool]$protectedRelease) -Message 'The expected pre-existing media-server environment is missing; refusing to run against an unexpected state.'

    $helmList = Get-NativeText -Executable 'helm' -Arguments @('list', '--namespace', 'media-server', '--output', 'json') -Operation 'Inspect existing protected Helm releases' | ConvertFrom-Json
    Assert-Phase0 -Condition (@($helmList | Where-Object { $_.name -eq 'media-server' }).Count -eq 1) -Message 'The pre-existing media-server Helm release was not found.'
    $deployment = Invoke-KubectlText -Arguments @('get', 'deployment', 'media-server', '--namespace', 'media-server', '-o', 'json') -Operation 'Fingerprint protected API Deployment' | ConvertFrom-Json
    $statefulSet = Invoke-KubectlText -Arguments @('get', 'statefulset', 'media-server-postgres', '--namespace', 'media-server', '-o', 'json') -Operation 'Fingerprint protected PostgreSQL StatefulSet' | ConvertFrom-Json
    $pvcs = Invoke-KubectlText -Arguments @('get', 'persistentvolumeclaims', '--namespace', 'media-server', '-o', 'json') -Operation 'Fingerprint protected media-server PVCs' | ConvertFrom-Json

    $claimFingerprint = @($pvcs.items | Sort-Object metadata.name | ForEach-Object { "$($_.metadata.name)=$($_.metadata.uid)" }) -join ';'
    $composeIds = @($protectedRelease -split "`n" | Where-Object { $_ } | Sort-Object) -join ','
    return [pscustomobject]@{
        Context = $context
        Server = $server
        NamespaceUid = [string]$protectedNamespace.metadata.uid
        ReleaseRevision = [string]$helmList[0].revision
        DeploymentUid = [string]$deployment.metadata.uid
        StatefulSetUid = [string]$statefulSet.metadata.uid
        ClaimFingerprint = $claimFingerprint
        ComposeContainerIds = $composeIds
    }
}

function Assert-ProtectedLocalBaseline {
    param([Parameter(Mandatory)]$Baseline)
    $current = Get-ProtectedLocalBaseline
    foreach ($property in @('Context', 'Server', 'NamespaceUid', 'DeploymentUid', 'StatefulSetUid', 'ClaimFingerprint', 'ComposeContainerIds')) {
        Assert-Phase0 -Condition ([string]$current.$property -eq [string]$Baseline.$property) -Message "Protected pre-existing media-server state changed during Phase 0 ($property)."
    }
}

function Get-KubernetesPod {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Selector)
    $pods = Invoke-KubectlText -Arguments @('get', 'pods', '--namespace', $Namespace, '--selector', $Selector, '-o', 'json') -Operation "Find Kubernetes pods for $Selector" | ConvertFrom-Json
    $running = @($pods.items | Where-Object { $_.status.phase -eq 'Running' } | Select-Object -First 1)
    if ($running.Count -eq 0) { return $null }
    return $running[0]
}

function Wait-KubernetesWorkloads {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Release, [Parameter()][int]$TimeoutSeconds = 360)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $api = Get-KubernetesPod -Namespace $Namespace -Selector "app.kubernetes.io/instance=$Release,app.kubernetes.io/component=api"
        $postgres = Get-KubernetesPod -Namespace $Namespace -Selector "app.kubernetes.io/instance=$Release,app.kubernetes.io/component=postgres"
        $mock = Get-KubernetesPod -Namespace $Namespace -Selector 'app.kubernetes.io/name=phase0-oauth-mock'
        $allReady = $api -and $postgres -and $mock
        foreach ($pod in @($api, $postgres, $mock)) {
            if (-not $pod) { $allReady = $false; break }
            if (@($pod.status.containerStatuses | Where-Object { -not $_.ready }).Count -gt 0) { $allReady = $false; break }
        }
        if ($allReady) { return [pscustomobject]@{ Api = $api; Postgres = $postgres; Mock = $mock } }
        Start-Sleep -Seconds 1
    }
    throw "Kubernetes Phase 0 workloads did not all become ready within $TimeoutSeconds seconds."
}

function ConvertTo-Base64Text {
    param([Parameter(Mandatory)][string]$Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Ensure-Phase0KubernetesImageImporter {
    param([Parameter(Mandatory)][string]$Namespace)
    $nodeInfo = Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'json') -Operation 'Read Docker Desktop Kubernetes node for local image import' | ConvertFrom-Json
    Assert-Phase0 -Condition (@($nodeInfo.items).Count -eq 1) -Message 'The Phase 0 image import expects the configured single-node local Kubernetes cluster.'
    $nodeName = [string]$nodeInfo.items[0].metadata.name
    $podName = 'phase0-image-import'
    $manifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
  labels:
    app.kubernetes.io/name: phase0-image-import
spec:
  nodeName: $nodeName
  restartPolicy: Never
  containers:
    - name: importer
      image: alpine:3.22
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
"@
    $manifestPath = Join-Path $script:TempRoot 'kubernetes-image-import-pod.yaml'
    Write-PrivateText -Path $manifestPath -Text $manifest
    $null = Invoke-KubectlText -Arguments @('apply', '--filename', $manifestPath) -Operation 'Create disposable Docker Desktop node image importer'
    $null = Invoke-KubectlText -Arguments @('wait', '--namespace', $Namespace, '--for=condition=Ready', "pod/$podName", '--timeout=180s') -Operation 'Wait for disposable Docker Desktop node image importer'
    $prerequisites = Invoke-KubectlText -Arguments @('exec', '--namespace', $Namespace, $podName, '--', 'sh', '-c', 'test -x /host/usr/local/bin/ctr && test -S /host/run/containerd/containerd.sock') -Operation 'Verify Docker Desktop node containerd image-import interface'
    return [pscustomobject]@{ PodName = $podName; NodeName = $nodeName; ManifestPath = $manifestPath }
}

function Import-Phase0KubernetesImages {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string[]]$Images)
    $importer = Ensure-Phase0KubernetesImageImporter -Namespace $Namespace
    foreach ($image in $Images) {
        $qualifiedImage = if ($image -notmatch '^[^/]+\.[^/]+/|^[^/]+:[0-9]+/') { "docker.io/library/$image" } else { $image }
        if (-not $script:ImportedKubernetesImages.Contains($qualifiedImage)) {
            $script:ImportedKubernetesImages.Add($qualifiedImage)
        }
    }

    $archiveName = "phase0-kubernetes-images-$($script:RunId).tar"
    $archivePath = Join-Path $script:TempRoot $archiveName
    Invoke-Logged -Executable $script:Docker -Arguments (@('save', '--output', $archivePath) + $Images) -Operation 'Export run-scoped images for local Kubernetes' -LogPath (Join-Path $script:Logs 'docker-save-kubernetes-images.log')
    Push-Location $script:TempRoot
    try {
        $null = Invoke-KubectlText -Arguments @('cp', $archiveName, "$Namespace/$($importer.PodName):/tmp/$archiveName") -Operation 'Copy run-scoped image archive to disposable node importer'
    }
    finally { Pop-Location }

    $importCommand = "set -eu; cp '/tmp/$archiveName' '/host/tmp/$archiveName'; chroot /host /usr/local/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io images import '/tmp/$archiveName'; rm -f '/host/tmp/$archiveName' '/tmp/$archiveName'; chroot /host /usr/local/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io images list --quiet"
    $importedReferences = Invoke-KubectlText -Arguments @('exec', '--namespace', $Namespace, $importer.PodName, '--', 'sh', '-c', $importCommand) -Operation 'Import Phase 0 images into the Docker Desktop Kubernetes containerd namespace'
    foreach ($image in $Images) {
        $tag = $image.Split(':')[-1]
        Assert-Phase0 -Condition ($importedReferences.Contains($tag)) -Message "The Docker Desktop Kubernetes image store is missing the imported tag $tag."
    }

    $evidence = [pscustomobject]@{
        node = $importer.NodeName
        runtime = 'Docker Desktop containerd namespace k8s.io'
        images = @($Images)
        importedTagsVerified = $true
        temporaryHostArchiveRemoved = $true
    }
    Write-Phase0Result -Name 'Run-scoped images imported into isolated local Kubernetes image store' -State 'PASS' -Evidence $evidence
    return $evidence
}

function Remove-Phase0KubernetesImages {
    if ($script:ImportedKubernetesImages.Count -eq 0) { return }
    if (-not $script:CreatedNamespace -or $script:CreatedNamespace -notmatch '^phase0-[0-9]{14}-[0-9]{4}$') {
        throw 'Refusing Kubernetes image cleanup without the validated Phase 0 namespace.'
    }

    $importer = Ensure-Phase0KubernetesImageImporter -Namespace $script:CreatedNamespace
    $archiveName = "phase0-kubernetes-images-$($script:RunId).tar"
    $imageRemovals = ($script:ImportedKubernetesImages | ForEach-Object { "chroot /host /usr/local/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io images remove '$_' >/dev/null 2>&1 || true;" }) -join ' '
    $removeScript = "set -eu; $imageRemovals rm -f `"/host/tmp/$archiveName`" `"/tmp/$archiveName`"; chroot /host /usr/local/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io images list --quiet"
    $removeArguments = @('exec', '--namespace', $script:CreatedNamespace, $importer.PodName, '--', 'sh', '-c', $removeScript)
    $remainingImages = Invoke-KubectlText -Arguments $removeArguments -Operation 'Remove run-scoped images from Docker Desktop Kubernetes containerd'
    foreach ($image in $script:ImportedKubernetesImages) {
        $tag = $image.Split(':')[-1]
        Assert-Phase0 -Condition (-not $remainingImages.Contains($tag)) -Message "Run-scoped Kubernetes image tag $tag remained after cleanup."
    }
    $script:ImportedKubernetesImages.Clear()
}

function Test-KubernetesDeployment {
    param([Parameter(Mandatory)]$Images)
    $namespace = "phase0-$($script:RunId)"
    $release = "media-server-phase0-$($script:RunId)"
    Assert-Phase0 -Condition ($namespace -match '^phase0-[0-9]{14}-[0-9]{4}$') -Message 'The generated Kubernetes namespace is not uniquely scoped.'
    $existing = Invoke-KubectlText -Arguments @('get', 'namespace', $namespace, '--ignore-not-found', '-o', 'name') -Operation 'Check unique Kubernetes namespace availability'
    Assert-Phase0 -Condition (-not $existing) -Message 'The unique Kubernetes namespace already exists; refusing to modify it.'

    $null = Invoke-KubectlText -Arguments @('create', 'namespace', $namespace) -Operation 'Create isolated Phase 0 Kubernetes namespace'
    $script:CreatedNamespace = $namespace
    $null = Import-Phase0KubernetesImages -Namespace $namespace -Images @($Images.DefaultImage, $Images.OAuthImage, $Images.MockImage)

    $httpPort = Get-FreeLoopbackPort
    $databasePassword = New-TestSecret
    $appSecret = New-TestSecret
    $oauthClientId = "phase0-$($script:RunId)"
    $oauthClientSecret = New-TestSecret
    $publicBaseUrl = "http://127.0.0.1:$httpPort"
    $databaseUrl = "postgresql://media_server:$databasePassword@${release}-postgres:5432/media_server"

    $secretManifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: phase0-postgres-secrets
  namespace: $namespace
type: Opaque
data:
  POSTGRES_PASSWORD: $(ConvertTo-Base64Text $databasePassword)
---
apiVersion: v1
kind: Secret
metadata:
  name: phase0-app-secrets
  namespace: $namespace
type: Opaque
data:
  MEDIA_SERVER_DATABASE_URL: $(ConvertTo-Base64Text $databaseUrl)
  MEDIA_SERVER_SECRET: $(ConvertTo-Base64Text $appSecret)
  MEDIA_SERVER_PUBLIC_BASE_URL: $(ConvertTo-Base64Text $publicBaseUrl)
  MEDIA_SERVER_ADMIN_EMAILS: $(ConvertTo-Base64Text 'phase0-admin@example.test')
  MEDIA_SERVER_AUTH_ALLOWLIST: $(ConvertTo-Base64Text 'phase0-admin@example.test,phase0-viewer@example.test')
  GOOGLE_CLIENT_ID: $(ConvertTo-Base64Text $oauthClientId)
  GOOGLE_CLIENT_SECRET: $(ConvertTo-Base64Text $oauthClientSecret)
"@
    $secretPath = Join-Path $script:TempRoot 'kubernetes-secrets.yaml'
    Write-PrivateText -Path $secretPath -Text $secretManifest
    $null = Invoke-KubectlText -Arguments @('apply', '--filename', $secretPath) -Operation 'Create disposable Kubernetes Secrets'

    $values = @"
image:
  repository: media-server-api
  tag: $($Images.OAuthImage.Split(':')[-1])
  pullPolicy: Never
app:
  existingSecret: phase0-app-secrets
  terminationGracePeriodSeconds: 240
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: "4"
      memory: 2Gi
postgres:
  auth:
    existingSecret: phase0-postgres-secrets
  persistence:
    size: 512Mi
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: "1"
      memory: 1Gi
persistence:
  media:
    size: 128Mi
  cache:
    size: 128Mi
extraEnv:
  MEDIA_SERVER_AUTH_ALLOWLIST: "phase0-admin@example.test,phase0-viewer@example.test"
  MEDIA_SERVER_TRANSCODE_PRESET: veryslow
"@
    $valuesPath = Join-Path $script:TempRoot 'kubernetes-values.yaml'
    Write-PrivateText -Path $valuesPath -Text $values
    Invoke-Logged -Executable 'helm' -Arguments @('upgrade', '--install', $release, (Join-Path $script:Snapshot 'deploy/helm/media-server'), '--namespace', $namespace, '--kube-context', 'docker-desktop', '--values', $valuesPath, '--wait', '--timeout', '6m') -Operation 'Install isolated Phase 0 Helm release' -LogPath (Join-Path $script:Logs 'helm-phase0-install.log')

    $mockManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phase0-oauth-mock
  namespace: $namespace
  labels:
    app.kubernetes.io/name: phase0-oauth-mock
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: phase0-oauth-mock
  template:
    metadata:
      labels:
        app.kubernetes.io/name: phase0-oauth-mock
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
      containers:
        - name: phase0-oauth-mock
          image: $($Images.MockImage)
          imagePullPolicy: Never
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PHASE0_MOCK_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: phase0-app-secrets
                  key: GOOGLE_CLIENT_ID
            - name: PHASE0_MOCK_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: phase0-app-secrets
                  key: GOOGLE_CLIENT_SECRET
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: phase0-oauth-mock
  namespace: $namespace
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: phase0-oauth-mock
  ports:
    - name: http
      port: 8080
      targetPort: http
"@
    $mockPath = Join-Path $script:TempRoot 'kubernetes-oauth-mock.yaml'
    Write-PrivateText -Path $mockPath -Text $mockManifest
    $null = Invoke-KubectlText -Arguments @('apply', '--filename', $mockPath) -Operation 'Create namespace-scoped OAuth mock Deployment and ClusterIP Service'

    $workloads = Wait-KubernetesWorkloads -Namespace $namespace -Release $release
    $apiPod = $workloads.Api
    $pgPod = $workloads.Postgres
    $mockPod = $workloads.Mock

    $deployment = Invoke-KubectlText -Arguments @('get', 'deployment', $release, '--namespace', $namespace, '-o', 'json') -Operation 'Inspect Phase 0 API Deployment' | ConvertFrom-Json
    $apiContainer = $deployment.spec.template.spec.containers | Where-Object { $_.name -eq 'media-server-api' } | Select-Object -First 1
    Assert-Phase0 -Condition ($deployment.spec.template.spec.terminationGracePeriodSeconds -eq 240) -Message 'Helm API pod does not retain a 240 second graceful termination period.'
    Assert-Phase0 -Condition ($apiContainer.securityContext.runAsUser -eq 10001 -and $apiContainer.securityContext.runAsGroup -eq 10001 -and $apiContainer.securityContext.readOnlyRootFilesystem -eq $true -and $apiContainer.securityContext.allowPrivilegeEscalation -eq $false) -Message 'Helm API security context is not non-root and read-only.'
    $mountNames = @($apiContainer.volumeMounts | ForEach-Object { $_.mountPath })
    foreach ($requiredMount in @('/media', '/cache', '/tmp')) {
        Assert-Phase0 -Condition ($mountNames -contains $requiredMount) -Message "Kubernetes API is missing its $requiredMount writable volume mount."
    }

    $service = Invoke-KubectlText -Arguments @('get', 'service', $release, '--namespace', $namespace, '-o', 'json') -Operation 'Inspect API Service exposure' | ConvertFrom-Json
    Assert-Phase0 -Condition ($service.spec.type -eq 'ClusterIP' -and $service.spec.selector.'app.kubernetes.io/component' -eq 'api' -and @($service.spec.ports).Count -eq 1 -and $service.spec.ports[0].port -eq 8000) -Message 'The Helm API Service is not a single-port ClusterIP selecting only API pods.'
    $postgresService = Invoke-KubectlText -Arguments @('get', 'service', "$release-postgres", '--namespace', $namespace, '-o', 'json') -Operation 'Inspect PostgreSQL Service exposure' | ConvertFrom-Json
    Assert-Phase0 -Condition ($postgresService.spec.type -eq 'ClusterIP' -and $postgresService.spec.selector.'app.kubernetes.io/component' -eq 'postgres') -Message 'The Helm PostgreSQL Service is not private ClusterIP-only.'
    $allServices = Invoke-KubectlText -Arguments @('get', 'services', '--namespace', $namespace, '-o', 'json') -Operation 'Inspect all Phase 0 Kubernetes Services' | ConvertFrom-Json
    Assert-Phase0 -Condition (@($allServices.items | Where-Object { $_.spec.type -ne 'ClusterIP' }).Count -eq 0) -Message 'A Phase 0 Kubernetes Service exposes a NodePort or LoadBalancer.'
    $claims = Invoke-KubectlText -Arguments @('get', 'persistentvolumeclaims', '--namespace', $namespace, '-o', 'json') -Operation 'Inspect Phase 0 Kubernetes persistent volume claims' | ConvertFrom-Json
    Assert-Phase0 -Condition (@($claims.items | Where-Object { $_.status.phase -ne 'Bound' }).Count -eq 0 -and $claims.items.Count -ge 3) -Message 'Kubernetes media/cache/database persistent volume claims are not all bound.'

    foreach ($pod in @($apiPod, $pgPod, $mockPod)) {
        foreach ($containerStatus in $pod.status.containerStatuses) {
            Assert-Phase0 -Condition ($containerStatus.imageID -match 'sha256:') -Message "Kubernetes container $($containerStatus.name) did not resolve to an immutable image ID."
        }
    }
    $apiUid = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'id', '-u') -Operation 'Inspect Kubernetes API runtime UID'
    $apiGid = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'id', '-g') -Operation 'Inspect Kubernetes API runtime GID'
    Assert-Phase0 -Condition ($apiUid -eq '10001' -and $apiGid -eq '10001') -Message 'Kubernetes API process did not run as UID/GID 10001.'
    $writeCheck = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', 'set -eu; for d in /media /cache /tmp; do f="$d/.phase0-write-check"; printf ok > "$f"; rm -f "$f"; done; if touch /app/.phase0-rootfs-check 2>/dev/null; then exit 42; fi') -Operation 'Verify Kubernetes writable mounts and read-only root filesystem'

    $origin = Start-KubernetesApiPortForward -Namespace $namespace -Release $release -LogSuffix 'initial'
    $spa = Invoke-Http -Uri "$origin/" -Method GET
    Assert-Phase0 -Condition ([int]$spa.StatusCode -eq 200 -and $spa.Headers['Content-Type'] -like 'text/html*') -Message 'The Helm React SPA endpoint did not return HTML.'
    $movies = Invoke-Http -Uri "$origin/api/movies" -Method GET
    Assert-Phase0 -Condition ([int]$movies.StatusCode -eq 200) -Message 'The Helm API could not read PostgreSQL.'

    $adminCallback = Wait-ForOAuthCallbackCookie -Origin $origin -Code 'phase0-admin-code'
    $adminCookie = Get-SessionCookie $adminCallback
    $adminIdentity = Invoke-Http -Uri "$origin/api/auth/me" -Method GET -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$adminIdentity.StatusCode -eq 200 -and $adminIdentity.Content -match 'phase0-admin@example\.test') -Message 'The Helm OAuth callback did not establish the allowed admin session.'
    $viewerCallback = Wait-ForOAuthCallbackCookie -Origin $origin -Code 'phase0-viewer-code'
    $viewerCookie = Get-SessionCookie $viewerCallback
    $viewerUpload = Invoke-Http -Uri "$origin/api/upload/chunk/init" -Method POST -Headers @{ Cookie = $viewerCookie } -Body (@{ filename = 'viewer-denied.bin'; size = 4 } | ConvertTo-Json -Compress)
    Assert-Phase0 -Condition ([int]$viewerUpload.StatusCode -eq 403) -Message 'The Helm OAuth viewer session was allowed to perform an admin upload.'
    $apiLogsBeforeReplacement = Invoke-KubectlText -Arguments @('logs', '--namespace', $namespace, $apiPod.metadata.name, '-c', 'media-server-api', '--tail=1000') -Operation 'Read initial isolated Kubernetes API pod logs for secret scan'

    $persistenceMarker = "phase0-$($script:RunId)"
    $persistFile = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', "printf '%s' '$persistenceMarker' > /media/.phase0-persistence-marker; printf '%s' '$persistenceMarker' > /cache/.phase0-persistence-marker") -Operation 'Write disposable PVC persistence markers'
    $sql = "CREATE TABLE IF NOT EXISTS phase0_persistence_markers (marker text PRIMARY KEY); INSERT INTO phase0_persistence_markers(marker) VALUES ('$persistenceMarker') ON CONFLICT (marker) DO NOTHING;"
    $insertMarker = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $pgPod.metadata.name, '--', 'psql', '-U', 'media_server', '-d', 'media_server', '-v', 'ON_ERROR_STOP=1', '-c', $sql) -Operation 'Insert disposable Kubernetes PostgreSQL persistence marker'

    $shutdownName = 'Phase0K8sShutdown.mkv'
    $generateCommand = "ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=180' -f lavfi -i 'sine=frequency=997:sample_rate=48000:duration=180' -shortest -c:v libx264 -preset ultrafast -tune zerolatency -crf 30 -pix_fmt yuv420p -c:a aac '/media/$shutdownName'"
    $null = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', $generateCommand) -Operation 'Generate disposable Kubernetes FFmpeg shutdown fixture'
    $shutdownStart = Invoke-Http -Uri "$origin/api/transcode/start/$(Get-EncodedPathSegment $shutdownName)?quality=360p" -Method POST -Body '{}' -ContentType 'application/json'
    Assert-Phase0 -Condition ([int]$shutdownStart.StatusCode -eq 200) -Message 'Kubernetes active FFmpeg shutdown transcode did not start.'
    $ffmpegDeadline = [DateTimeOffset]::UtcNow.AddSeconds(45)
    $activeFfmpeg = ''
    while ([DateTimeOffset]::UtcNow -lt $ffmpegDeadline) {
        $activeFfmpeg = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', "ps -eo args | grep '[f]fmpeg' | grep -F '$shutdownName' || true") -Operation 'Inspect active Kubernetes FFmpeg child process'
        if ($activeFfmpeg) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-Phase0 -Condition ([bool]$activeFfmpeg) -Message 'Kubernetes API did not have an active FFmpeg child before pod deletion.'

    $podDeletion = [System.Diagnostics.Stopwatch]::StartNew()
    $oldApiPodUid = [string]$apiPod.metadata.uid
    $null = Invoke-KubectlText -Arguments @('delete', 'pod', $apiPod.metadata.name, '--namespace', $namespace, '--grace-period=240', '--wait=true', '--timeout=270s') -Operation 'Delete Kubernetes API pod during active FFmpeg transcode'
    $podDeletion.Stop()
    $workloads = Wait-KubernetesWorkloads -Namespace $namespace -Release $release
    $apiPod = $workloads.Api
    Assert-Phase0 -Condition ($apiPod.metadata.uid -ne $oldApiPodUid) -Message 'Kubernetes API pod was not replaced after termination.'
    $previousPortForward = $script:PortForwards[$script:PortForwards.Count - 1]
    Stop-KubernetesApiPortForward -Process $previousPortForward
    $origin = Start-KubernetesApiPortForward -Namespace $namespace -Release $release -LogSuffix 'after-api-replacement'
    $interruptedJobSql = "SELECT status FROM transcode_jobs WHERE filename = '$shutdownName' AND mode = 'hls:360p'"
    $interruptedJobStatus = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $workloads.Postgres.metadata.name, '--', 'psql', '-U', 'media_server', '-d', 'media_server', '-tAc', $interruptedJobSql) -Operation 'Read interrupted Kubernetes transcode job state after API pod restart'
    Assert-Phase0 -Condition ($interruptedJobStatus.Trim() -eq 'failed') -Message 'Interrupted Kubernetes transcode job did not reconcile to failed after API pod restart.'
    $orphanFfmpeg = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', "ps -eo args | grep '[f]fmpeg' | grep -F '$shutdownName' || true") -Operation 'Check Kubernetes FFmpeg child cleanup after API pod restart'
    Assert-Phase0 -Condition (-not $orphanFfmpeg) -Message 'Kubernetes API replacement pod found a lingering FFmpeg child for the interrupted transcode.'
    $mediaPersisted = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $apiPod.metadata.name, '--', 'sh', '-c', "test `"`$(cat /media/.phase0-persistence-marker)`" = '$persistenceMarker' && test `"`$(cat /cache/.phase0-persistence-marker)`" = '$persistenceMarker'") -Operation 'Verify media and cache PVC persistence after API pod replacement'
    $apiAfterRestart = Wait-HttpStatus -Uri "$origin/api/movies" -ExpectedStatus 200 -TimeoutSeconds 120
    $sessionAfterRestart = Invoke-Http -Uri "$origin/api/auth/me" -Method GET -Headers @{ Cookie = $adminCookie }
    Assert-Phase0 -Condition ([int]$sessionAfterRestart.StatusCode -eq 200 -and $sessionAfterRestart.Content -match 'phase0-admin@example\.test') -Message 'The Kubernetes API session did not survive pod replacement.'

    $pgPodNameBefore = [string]$workloads.Postgres.metadata.name
    $null = Invoke-KubectlText -Arguments @('delete', 'pod', $pgPodNameBefore, '--namespace', $namespace, '--wait=true', '--timeout=150s') -Operation 'Recreate isolated Kubernetes PostgreSQL pod'
    $workloads = Wait-KubernetesWorkloads -Namespace $namespace -Release $release
    $pgPod = $workloads.Postgres
    $markerQuery = "SELECT count(*) FROM phase0_persistence_markers WHERE marker = '$persistenceMarker'"
    $markerCount = Invoke-KubectlText -Arguments @('exec', '--namespace', $namespace, $pgPod.metadata.name, '--', 'psql', '-U', 'media_server', '-d', 'media_server', '-tAc', $markerQuery) -Operation 'Verify PostgreSQL PVC marker after pod recreation'
    Assert-Phase0 -Condition ($markerCount.Trim() -eq '1') -Message 'The Kubernetes PostgreSQL PVC did not preserve its marker across pod replacement.'
    $apiAfterPgRestart = Wait-HttpStatus -Uri "$origin/api/movies" -ExpectedStatus 200 -TimeoutSeconds 120

    $apiLogsAfterReplacement = Invoke-KubectlText -Arguments @('logs', '--namespace', $namespace, $apiPod.metadata.name, '-c', 'media-server-api', '--tail=1000') -Operation 'Read replacement Kubernetes API pod logs for secret scan'
    $apiLogs = "$apiLogsBeforeReplacement`n$apiLogsAfterReplacement"
    $mockLogs = Invoke-KubectlText -Arguments @('logs', '--namespace', $namespace, $mockPod.metadata.name, '-c', 'phase0-oauth-mock', '--tail=1000') -Operation 'Read isolated OAuth mock pod logs for secret scan'
    $pgLogs = Invoke-KubectlText -Arguments @('logs', '--namespace', $namespace, $pgPod.metadata.name, '-c', 'postgres', '--tail=1000') -Operation 'Read isolated PostgreSQL pod logs for secret scan'
    $kubernetesLogSources = @(
        [pscustomobject]@{ Name = 'API'; Text = $apiLogs },
        [pscustomobject]@{ Name = 'OAuth mock'; Text = $mockLogs },
        [pscustomobject]@{ Name = 'PostgreSQL'; Text = $pgLogs }
    )
    $kubernetesCredentials = @(
        [pscustomobject]@{ Name = 'database password'; Value = $databasePassword },
        [pscustomobject]@{ Name = 'application secret'; Value = $appSecret },
        [pscustomobject]@{ Name = 'OAuth client secret'; Value = $oauthClientSecret },
        [pscustomobject]@{ Name = 'OAuth client ID'; Value = $oauthClientId }
    )
    foreach ($credential in $kubernetesCredentials) {
        foreach ($logSource in $kubernetesLogSources) {
            if ($logSource.Text.Contains($credential.Value)) {
                $redactedLog = $logSource.Text.Replace($credential.Value, '[redacted]')
                $matchingLines = @($redactedLog -split "`r?`n" | Where-Object { $_.Contains('[redacted]') } | Select-Object -First 3)
                throw "Generated $($credential.Name) appeared in Kubernetes $($logSource.Name) logs. Redacted line(s): $($matchingLines -join ' | ')"
            }
        }
    }

    Write-Phase0Result -Name 'Isolated Helm/Kubernetes readiness, identity, private Services, read-only root, OAuth, active-transcode termination, and PVC persistence' -State 'PASS' -Evidence ([pscustomobject]@{
        context = 'docker-desktop loopback API'
        namespace = $namespace
        apiPodReady = $true
        postgresPodReady = $true
        apiImageID = [string]$apiPod.status.containerStatuses[0].imageID
        apiUid = $apiUid
        apiGid = $apiGid
        readOnlyRootFilesystem = $true
        writableMountedPaths = @('/media', '/cache', '/tmp')
        serviceTypes = @($allServices.items | ForEach-Object { "$($_.metadata.name):$($_.spec.type)" })
        postgresNodePortOrLoadBalancer = $false
        boundClaimCount = $claims.items.Count
        interruptedJobStatus = $interruptedJobStatus.Trim()
        orphanFfmpegAfterRestart = $false
        oauthAdminSession = [int]$adminIdentity.StatusCode
        oauthViewerDeniedUpload = [int]$viewerUpload.StatusCode
        activeFfmpegObserved = $true
        apiPodTerminationSeconds = [math]::Round($podDeletion.Elapsed.TotalSeconds, 2)
        mediaAndCachePVCsSurvivedApiReplacement = $true
        postgresPVCMarkerCount = [int]$markerCount.Trim()
        apiAfterPostgresRestart = [int]$apiAfterPgRestart.StatusCode
        sessionSurvivedApiReplacement = $true
        logCredentialLeaks = 0
    })

    return [pscustomobject]@{
        Namespace = $namespace
        Release = $release
        DatabasePassword = $databasePassword
        AppSecret = $appSecret
        OAuthClientSecret = $oauthClientSecret
        OAuthClientId = $oauthClientId
    }
}

function Test-SecretScanner {
    $scannerImage = 'zricethezav/gitleaks:latest'
    Invoke-Logged -Executable $script:Docker -Arguments @('pull', $scannerImage) -Operation 'Pull Gitleaks scanner image' -LogPath (Join-Path $script:Logs 'gitleaks-pull.log')
    $mount = "type=bind,source=$($script:Snapshot),target=/repo,readonly"
    Invoke-Logged -Executable $script:Docker -Arguments @('run', '--rm', '--mount', $mount, $scannerImage, 'detect', '--no-git', '--source=/repo', '--redact=100', '--exit-code', '1', '--no-banner') -Operation 'Scan clean source snapshot with Gitleaks' -LogPath (Join-Path $script:Logs 'gitleaks.log')
    Write-Phase0Result -Name 'Gitleaks scan of clean source snapshot' -State 'PASS' -Evidence ([pscustomobject]@{ source = 'tracked and non-ignored source snapshot'; report = 'no findings' })
}

function Test-CiRegressionGates {
    foreach ($tool in @('python', 'npm', 'flutter')) { $null = Get-Command $tool -ErrorAction Stop }

    $fixtureRoot = Join-Path $script:TempRoot 'rust-test-fixtures'
    $mediaRoot = Join-Path $fixtureRoot 'media'
    $cacheRoot = Join-Path $script:TempRoot 'rust-test-cache'
    $staticRoot = Join-Path $script:Snapshot 'web/dist'
    New-Item -ItemType Directory -Path $mediaRoot, $cacheRoot, (Join-Path $staticRoot 'assets'), (Join-Path $script:Snapshot 'updates/production') -Force | Out-Null
    $sampleVideo = Join-Path $mediaRoot 'sample_test_movie.mp4'
    New-SyntheticMedia -Path $sampleVideo -Duration '1' -Size '320x240'
    Write-PrivateText -Path (Join-Path $staticRoot 'index.html') -Text '<!DOCTYPE html><html><head><title>Anis Media Server</title></head><body><div id="root"></div></body></html>'
    Write-PrivateText -Path (Join-Path $staticRoot 'assets/test.js') -Text 'console.log("synthetic test asset");'
    $manifest = @'
{
  "channel": "production",
  "version": "1.4.0",
  "versionCode": 146,
  "releaseDate": "2026-10-24T19:42:35.982809+00:00",
  "minAndroidSdk": 24,
  "targetAndroidSdk": 36,
  "packageId": "in.anisparvez.media_server_client",
  "apkUrl": "/api/app/download?channel=production",
  "sha256": "5832f2953110ba7783bcbe8fb1e8d2e6c9b09cbc979d3cb6919335576502f4d0",
  "fileSizeBytes": 11534336,
  "releaseNotes": "CI Synthetic Test Release",
  "mandatory": false,
  "minSupportedVersionCode": 1,
  "gitCommit": "c7861ed"
}
'@
    Write-PrivateText -Path (Join-Path $script:Snapshot 'updates/production/manifest.json') -Text $manifest
    $apkPath = Join-Path $script:Snapshot 'updates/production/media-server-client.apk'
    $apkStream = [System.IO.File]::Create($apkPath)
    try { $apkStream.SetLength(11534336) } finally { $apkStream.Dispose() }

    $databasePassword = New-TestSecret
    $databaseName = "phase0-rust-postgres-$($script:RunId)"
    $networkName = "phase0-rust-network-$($script:RunId)"
    $existingDb = Get-NativeText -Executable $script:Docker -Arguments @('ps', '-aq', '--filter', "name=^/$databaseName$") -Operation 'Check unique Rust test PostgreSQL container name'
    Assert-Phase0 -Condition (-not $existingDb) -Message 'The unique Rust test database container name already exists.'
    $existingNetwork = Get-NativeText -Executable $script:Docker -Arguments @('network', 'ls', '-q', '--filter', "name=^$networkName$") -Operation 'Check unique Rust test network name'
    Assert-Phase0 -Condition (-not $existingNetwork) -Message 'The unique Rust test network name already exists.'
    Invoke-Logged -Executable $script:Docker -Arguments @('network', 'create', $networkName) -Operation 'Create private Rust test network' -LogPath (Join-Path $script:Logs 'rust-test-network-create.log')
    $script:DisposableNetworks.Add($networkName)
    $script:DisposableDbContainers.Add($databaseName)
    $dbEnvPath = Join-Path $script:TempRoot 'rust-test-postgres.env'
    Write-PrivateText -Path $dbEnvPath -Text "POSTGRES_USER=postgres`nPOSTGRES_PASSWORD=$databasePassword`nPOSTGRES_DB=media_server_test`n"
    Invoke-Logged -Executable $script:Docker -Arguments @('run', '--detach', '--name', $databaseName, '--network', $networkName, '--network-alias', 'phase0-postgres', '--env-file', $dbEnvPath, '--health-cmd', 'pg_isready -U postgres -d media_server_test', '--health-interval', '2s', '--health-timeout', '2s', '--health-retries', '40', 'postgres:17-alpine') -Operation 'Start disposable PostgreSQL service for CI-equivalent Rust tests' -LogPath (Join-Path $script:Logs 'rust-test-postgres-start.log')
    $dbDeadline = [DateTimeOffset]::UtcNow.AddSeconds(120)
    do {
        $dbHealth = Get-NativeText -Executable $script:Docker -Arguments @('inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}', $databaseName) -Operation 'Check disposable Rust test PostgreSQL readiness'
        if ($dbHealth -eq 'healthy') { break }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $dbDeadline)
    Assert-Phase0 -Condition ($dbHealth -eq 'healthy') -Message 'Disposable PostgreSQL did not become healthy for Rust regression tests.'

    $databaseUrl = "postgresql://postgres:$databasePassword@phase0-postgres:5432/media_server_test"
    $testSecret = New-TestSecret
    $script:Redactions.Add($databaseUrl)
    $testVariables = @(
        'CARGO_TERM_COLOR=never'
        'RUST_BACKTRACE=1'
        'RUST_TEST_THREADS=1'
        "MEDIA_SERVER_DATABASE_URL=$databaseUrl"
        "MEDIA_SERVER_TEST_DATABASE_URL=$databaseUrl"
        "DATABASE_URL=$databaseUrl"
        'MEDIA_SERVER_MEDIA_ROOT=/fixtures/media'
        'MEDIA_SERVER_MEDIA_ROOTS=/fixtures/media'
        'MEDIA_SERVER_CACHE_DIR=/fixtures/cache'
        'MEDIA_SERVER_BASE_DIR=/workspace'
        'MEDIA_SERVER_STATIC_DIR=/workspace/web/dist'
        "MEDIA_SERVER_SECRET=$testSecret"
        'MEDIA_SERVER_PUBLIC_BASE_URL=http://127.0.0.1:18000'
        'MEDIA_SERVER_AUTH=false'
        'MEDIA_SERVER_AUTH_ALLOWLIST='
        'MEDIA_SERVER_ADMIN_EMAILS='
        'MEDIA_SERVER_GOOGLE_CLIENT_ID='
        'MEDIA_SERVER_GOOGLE_CLIENT_SECRET='
        'GOOGLE_CLIENT_ID='
        'GOOGLE_CLIENT_SECRET='
        'TMDB_API_TOKEN='
        'MEDIA_SERVER_TMDB_API_TOKEN='
        'MEDIA_SERVER_UPLOAD_TMP=/fixtures/media/.uploads'
        'MEDIA_SERVER_UPLOAD_TARGET_DIR=/fixtures/media'
        'MEDIA_SERVER_ARCHIVE_DIR=/fixtures/media/.archive'
    )
    $testEnvPath = Join-Path $script:TempRoot 'rust-test.env'
    Write-PrivateText -Path $testEnvPath -Text (($testVariables -join "`n") + "`n")
    $sourceMount = "type=bind,source=$($script:Snapshot),target=/workspace"
    $fixtureMount = "type=bind,source=$fixtureRoot,target=/fixtures"
    $linuxCommand = 'set -e; export CARGO_NET_RETRY=10; export CARGO_TARGET_DIR=/tmp/phase0-cargo-target; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pkg-config libssl-dev ffmpeg; rustup component add clippy; rustc --version; cargo clippy --version; cargo test --manifest-path /workspace/rust/Cargo.toml --locked --no-fail-fast -- --test-threads=1; cargo clippy --manifest-path /workspace/rust/Cargo.toml --all-targets -- -D warnings'
    Invoke-Logged -Executable $script:Docker -Arguments @('run', '--rm', '--network', $networkName, '--dns', '8.8.8.8', '--dns', '1.1.1.1', '--mount', $sourceMount, '--mount', $fixtureMount, '--mount', 'type=volume,source=phase0-cargo-registry,target=/usr/local/cargo/registry', '--env-file', $testEnvPath, '--workdir', '/workspace/rust', 'rust:1.99-bookworm', 'bash', '-c', $linuxCommand) -Operation 'Run full Rust unit and integration suite against disposable PostgreSQL' -LogPath (Join-Path $script:Logs 'cargo-ci-linux.log')
    $rustTestLines = @(Get-Content -LiteralPath (Join-Path $script:Logs 'cargo-ci-linux.log') | Where-Object { $_ -match 'test result:|Finished `dev` profile' })
    $rustToolchainLines = @(Get-Content -LiteralPath (Join-Path $script:Logs 'cargo-ci-linux.log') | Where-Object { $_ -match '^(rustc|clippy) ' })
    Write-Phase0Result -Name 'Rust unit/integration tests, disposable PostgreSQL, and Clippy' -State 'PASS' -Evidence ([pscustomobject]@{ toolchain = $rustToolchainLines; testResultLines = $rustTestLines; clippy = 'pass'; fixtureDatabase = 'media_server_test on un-published unique Docker network' })

    $webDirectory = Join-Path $script:Snapshot 'web'
    Push-Location $webDirectory
    try {
        Invoke-Logged -Executable 'npm' -Arguments @('ci', '--no-audit', '--no-fund') -Operation 'Install isolated React frontend dependencies' -LogPath (Join-Path $script:Logs 'npm-ci.log')
        Invoke-Logged -Executable 'npm' -Arguments @('run', 'typecheck') -Operation 'Run React TypeScript typecheck' -LogPath (Join-Path $script:Logs 'npm-typecheck.log')
        Invoke-Logged -Executable 'npm' -Arguments @('run', 'lint') -Operation 'Run React oxlint checks' -LogPath (Join-Path $script:Logs 'npm-lint.log')
        Invoke-Logged -Executable 'npm' -Arguments @('run', 'test') -Operation 'Run React Vitest unit suite' -LogPath (Join-Path $script:Logs 'npm-test.log')
        Invoke-Logged -Executable 'npm' -Arguments @('run', 'build') -Operation 'Build React production bundle' -LogPath (Join-Path $script:Logs 'npm-build.log')
    }
    finally { Pop-Location }
    $vitestSummary = @(Get-Content -LiteralPath (Join-Path $script:Logs 'npm-test.log') | Where-Object { $_ -match 'Test Files|Tests ' } | Select-Object -Last 4)
    Write-Phase0Result -Name 'React typecheck, lint, Vitest suite, and production build' -State 'PASS' -Evidence ([pscustomobject]@{ vitest = $vitestSummary; typecheck = 'pass'; lint = 'pass'; build = 'pass' })

    $flutterDirectory = Join-Path $script:Snapshot 'flutter_client'
    $flutterRunner = Join-Path $script:Snapshot 'scripts/run_flutter_tests.ps1'
    Push-Location $flutterDirectory
    try {
        Invoke-Logged -Executable 'flutter' -Arguments @('pub', 'get') -Operation 'Resolve isolated Flutter dependencies' -LogPath (Join-Path $script:Logs 'flutter-pub-get.log')
        Invoke-Logged -Executable 'flutter' -Arguments @('analyze') -Operation 'Run Flutter static analysis' -LogPath (Join-Path $script:Logs 'flutter-analyze.log')
        if (Test-Path -LiteralPath $flutterRunner) {
            Invoke-Logged -Executable 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $flutterRunner, '-SkipAnalyze') -Operation 'Run Flutter unit and widget suite' -LogPath (Join-Path $script:Logs 'flutter-test.log')
        }
        else {
            Invoke-Logged -Executable 'flutter' -Arguments @('test') -Operation 'Run Flutter unit and widget suite' -LogPath (Join-Path $script:Logs 'flutter-test.log')
        }
    }
    finally { Pop-Location }
    $flutterTestSummary = @(Get-Content -LiteralPath (Join-Path $script:Logs 'flutter-test.log') -Tail 20 | Where-Object { $_ -match 'All tests passed|Some tests failed' } | Select-Object -Last 1)
    Write-Phase0Result -Name 'Flutter dependency resolution, analyze, and unit/widget tests' -State 'PASS' -Evidence ([pscustomobject]@{ testSummary = $flutterTestSummary; analyze = 'pass' })

    $dbStop = Invoke-DockerText -Arguments @('rm', '--force', $databaseName) -Operation 'Remove disposable Rust test PostgreSQL container'
    Write-Phase0Result -Name 'Disposable Rust test database cleanup' -State 'PASS' -Evidence ([pscustomobject]@{ container = $databaseName; removed = $true })
    $script:DisposableDbContainers.Remove($databaseName) | Out-Null
    $networkRemoval = Invoke-DockerText -Arguments @('network', 'rm', $networkName) -Operation 'Remove private Rust test network'
    $script:DisposableNetworks.Remove($networkName) | Out-Null
}

function Invoke-Cleanup {
    $prevCleanup = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        foreach ($process in @($script:PortForwards.ToArray())) {
        try {
            if (-not $process.HasExited) {
                try { $process.Kill($true) } catch { $process.Kill() }
                $process.WaitForExit(5000) | Out-Null
            }
            if (-not $process.HasExited) { throw 'Port-forward process is still active after termination.' }
            $script:PortForwards.Remove($process) | Out-Null
        }
        catch {
            $script:CleanupWarnings.Add('Could not stop a Phase 0 kubectl port-forward process.')
            Write-Host '[CLEANUP-WARN] Could not stop a Phase 0 kubectl port-forward process.'
        }
    }

    foreach ($project in @($script:ComposeProjects.ToArray())) {
        if ($project.Name -match "^phase0-[a-z0-9-]*$" -and $project.Name.Contains($script:RunId)) {
            try {
                $cleanupLog = Join-Path $script:Logs "cleanup-$($project.Name).log"
                $prefix = Get-ComposePrefix -Project $project.Name -EnvironmentFile $project.EnvironmentFile -OverrideFile $project.OverrideFile
                Invoke-Logged -Executable $script:Docker -Arguments ($prefix + @('down', '--volumes', '--remove-orphans')) -Operation 'Clean isolated Phase 0 Compose resources' -LogPath $cleanupLog
                $script:ComposeProjects.Remove($project) | Out-Null
            }
            catch {
                $script:CleanupWarnings.Add("Compose cleanup failed for isolated project $($project.Name).")
                Write-Host "[CLEANUP-WARN] Compose cleanup failed for isolated project $($project.Name)."
            }
        }
    }

    if ($script:CreatedNamespace -and $script:CreatedNamespace -match '^phase0-[0-9]{14}-[0-9]{4}$') {
        try {
            # The actual release prefix includes the chart name and the unique run id.
            $runSuffix = $script:CreatedNamespace.Substring('phase0-'.Length)
            $release = "media-server-phase0-$runSuffix"
            $releasePresent = & helm list --namespace $script:CreatedNamespace --output json 2>$null | ConvertFrom-Json
            if (@($releasePresent | Where-Object { $_.name -eq $release }).Count -gt 0) {
                & helm uninstall $release --namespace $script:CreatedNamespace --wait --timeout 3m *> (Join-Path $script:Logs 'cleanup-helm-uninstall.log')
                if ($LASTEXITCODE -ne 0) { throw 'Helm uninstall returned a non-zero exit code.' }
            }
        }
        catch {
            $script:CleanupWarnings.Add('Helm uninstall failed for the unique Phase 0 release.')
            Write-Host '[CLEANUP-WARN] Helm uninstall failed for the unique Phase 0 release.'
        }
        try {
            $null = Invoke-KubectlText -Arguments @('delete', 'deployment/phase0-oauth-mock', 'service/phase0-oauth-mock', '--namespace', $script:CreatedNamespace, '--ignore-not-found=true', '--wait=true', '--timeout=3m') -Operation 'Remove isolated Kubernetes OAuth mock resources'
        }
        catch {
            $script:CleanupWarnings.Add('OAuth mock cleanup failed in the unique Phase 0 namespace.')
            Write-Host '[CLEANUP-WARN] OAuth mock cleanup failed in the unique Phase 0 namespace.'
        }
        try { Remove-Phase0KubernetesImages }
        catch {
            $cleanupDetail = [string]$_.Exception.Message
            $script:CleanupWarnings.Add("Run-scoped images could not be removed from the local Kubernetes image store: $cleanupDetail")
            Write-Host "[CLEANUP-WARN] Run-scoped Kubernetes image removal failed: $cleanupDetail"
        }
        try {
            $namespacePresent = & $script:Kubectl get namespace $script:CreatedNamespace --ignore-not-found -o name 2>$null
            if ($namespacePresent) {
                & $script:Kubectl delete namespace $script:CreatedNamespace --wait=true --timeout=3m *> (Join-Path $script:Logs 'cleanup-namespace-delete.log')
                if ($LASTEXITCODE -ne 0) { throw 'Namespace deletion returned a non-zero exit code.' }
            }
            $remainingNamespace = Get-NativeText -Executable $script:Kubectl -Arguments @('get', 'namespace', $script:CreatedNamespace, '--ignore-not-found', '-o', 'name') -Operation 'Verify unique Phase 0 namespace removal'
            if ($remainingNamespace) { throw 'The unique Phase 0 namespace remains after cleanup.' }
            $script:CreatedNamespace = $null
        }
        catch {
            $script:CleanupWarnings.Add('Namespace cleanup failed for the unique Phase 0 namespace.')
            Write-Host '[CLEANUP-WARN] Namespace cleanup failed for the unique Phase 0 namespace.'
        }
    }

    foreach ($image in @($script:CreatedImages.ToArray())) {
        try {
            & $script:Docker image rm $image *> $null
            if ($LASTEXITCODE -ne 0) { throw "Docker could not remove $image." }
            $script:CreatedImages.Remove($image) | Out-Null
        }
        catch {
            $script:CleanupWarnings.Add("Docker image cleanup failed for $image.")
            Write-Host "[CLEANUP-WARN] Docker image cleanup failed for $image."
        }
    }
    foreach ($container in @($script:DisposableDbContainers.ToArray())) {
        try {
            & $script:Docker rm --force $container *> $null
            if ($LASTEXITCODE -ne 0) { throw "Docker could not remove $container." }
            $script:DisposableDbContainers.Remove($container) | Out-Null
        }
        catch {
            $script:CleanupWarnings.Add("Disposable PostgreSQL cleanup failed for $container.")
            Write-Host "[CLEANUP-WARN] Disposable PostgreSQL cleanup failed for $container."
        }
    }
    foreach ($network in @($script:DisposableNetworks.ToArray())) {
        try {
            & $script:Docker network rm $network *> $null
            if ($LASTEXITCODE -ne 0) { throw "Docker could not remove $network." }
            $script:DisposableNetworks.Remove($network) | Out-Null
        }
        catch {
            $script:CleanupWarnings.Add("Disposable network cleanup failed for $network.")
            Write-Host "[CLEANUP-WARN] Disposable network cleanup failed for $network."
        }
    }

        if ($script:TempRootCreated -and $script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
            $expectedParent = [System.IO.Path]::GetFullPath($script:TempParent).TrimEnd('\') + '\'
            $fullTempRoot = [System.IO.Path]::GetFullPath($script:TempRoot)
            if ($fullTempRoot.StartsWith($expectedParent, [System.StringComparison]::OrdinalIgnoreCase) -and $fullTempRoot -match "media-server-phase0-$([regex]::Escape($script:RunId))$") {
                try {
                    Remove-Item -LiteralPath $fullTempRoot -Recurse -Force
                    if (Test-Path -LiteralPath $fullTempRoot) { throw 'Verified Phase 0 temp directory remains.' }
                    $script:TempRootCreated = $false
                }
                catch {
                    $script:CleanupWarnings.Add('Could not remove the verified unique Phase 0 temp directory.')
                    Write-Host '[CLEANUP-WARN] Could not remove the verified unique Phase 0 temp directory.'
                }
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevCleanup
    }
    $env:PATH = $script:OriginalPath
}

if ($CleanupRunId) {
    $script:RunId = $CleanupRunId
    $script:TempRoot = Join-Path $script:TempParent "media-server-phase0-$($script:RunId)"
    $script:TempRootCreated = $true
    Assert-Phase0 -Condition (Test-Path -LiteralPath $script:TempRoot -PathType Container) -Message 'The requested Phase 0 cleanup directory does not exist.'
    $cleanupRoot = [System.IO.Path]::GetFullPath($script:TempRoot)
    $cleanupParent = [System.IO.Path]::GetFullPath($script:TempParent).TrimEnd('\') + '\'
    Assert-Phase0 -Condition ($cleanupRoot.StartsWith($cleanupParent, [System.StringComparison]::OrdinalIgnoreCase) -and $cleanupRoot -match "media-server-phase0-$([regex]::Escape($script:RunId))$") -Message 'Refusing cleanup because the requested directory is outside the unique Phase 0 temp root.'
    Invoke-Cleanup
    exit 0
}

try {
    Assert-Phase0 -Condition (-not (Test-Path -LiteralPath $script:TempRoot)) -Message 'The unique Phase 0 temp path already exists; refusing to reuse or delete it.'
    New-Item -ItemType Directory -Path $script:TempRoot, $script:Snapshot, $script:Logs -Force | Out-Null
    $script:TempRootCreated = $true
    Assert-Phase0 -Condition (Test-Path -LiteralPath $script:Docker -PathType Leaf) -Message 'Docker Desktop CLI was not found at its configured local path.'
    $dockerDirectory = Split-Path -Parent $script:Docker
    if (-not (($env:PATH -split ';') -contains $dockerDirectory)) {
        $env:PATH = "$dockerDirectory;$env:PATH"
    }
    Assert-Phase0 -Condition (Test-Path -LiteralPath $script:Kubectl -PathType Leaf) -Message 'kubectl was not found at its configured local path.'
    foreach ($tool in @('git', 'helm', 'ffmpeg', 'ffprobe', 'cargo')) {
        $null = Get-Command $tool -ErrorAction Stop
    }

    $script:ProtectedBaseline = Get-ProtectedLocalBaseline
    $script:SourceInfo = New-SourceSnapshot
    Assert-Phase0 -Condition ($script:SourceInfo.contextFileCount -gt 0 -and $script:SourceInfo.contextBytes -gt 0) -Message 'The Docker build context is unexpectedly empty.'
    $revisionTag = $script:SourceInfo.snapshotSha256.Substring(0, 12)

    $formatLog = Join-Path $script:Logs 'cargo-fmt.log'
    Invoke-Logged -Executable 'cargo' -Arguments @('fmt', '--all', '--check', '--manifest-path', (Join-Path $script:Snapshot 'rust/Cargo.toml')) -Operation 'Check Rust formatting on clean source snapshot' -LogPath $formatLog
    Invoke-Logged -Executable 'helm' -Arguments @('lint', (Join-Path $script:Snapshot 'deploy/helm/media-server')) -Operation 'Lint media-server Helm chart' -LogPath (Join-Path $script:Logs 'helm-lint.log')
    Invoke-Logged -Executable 'helm' -Arguments @('template', 'phase0-render-check', (Join-Path $script:Snapshot 'deploy/helm/media-server')) -Operation 'Render media-server Helm chart' -LogPath (Join-Path $script:Logs 'helm-template.yaml')
    Write-Phase0Result -Name 'Rust formatting and Helm lint/template' -State 'PASS' -Evidence ([pscustomobject]@{ cargoFmt = 'pass'; helmLint = 'pass'; helmTemplate = 'pass' })

    $config = Test-ComposeConfiguration -Label 'Compose configuration regression'
    $images = Build-Phase0Images -RevisionTag $revisionTag -ReuseBuildCache:$ReuseBuildCache
    if (-not $KubernetesOnly) {
        Test-OAuthDisabledAndProductionTarget -Image $images.DefaultImage
        $null = Test-ComposeEndToEnd -ApiImage $images.OAuthImage -MockImage $images.MockImage
        Test-SecretScanner
        Test-CiRegressionGates
    }
    $null = Test-KubernetesDeployment -Images $images
    Assert-ProtectedLocalBaseline -Baseline $script:ProtectedBaseline
    if (-not $KubernetesOnly) {
        Write-Phase0Result -Name 'Pre-existing Compose and Helm resources preserved' -State 'PASS' -Evidence ([pscustomobject]@{
            composeProject = 'mediaserver'
            composeContainerIdsUnchanged = $true
            helmNamespace = 'media-server'
            helmDeploymentAndStatefulSetUidsUnchanged = $true
            pvcNamesAndUidsUnchanged = $true
        })
    }

    Invoke-Cleanup
    Assert-Phase0 -Condition ($script:CleanupWarnings.Count -eq 0) -Message ("Phase 0 cleanup warnings: {0}" -f ($script:CleanupWarnings -join ' | '))
    Write-Phase0Result -Name 'Run-scoped Compose, Kubernetes, image, database, network, and temp resources removed' -State 'PASS' -Evidence ([pscustomobject]@{
        composeProjectsRemoved = $true
        kubernetesNamespaceRemoved = $true
        kubernetesImagesRemoved = $true
        localImagesRemoved = $true
        disposableDatabaseAndNetworkRemoved = $true
        temporarySecretsLogsAndFixturesRemoved = $true
    })

    $summary = [pscustomobject]@{
        goal = if ($KubernetesOnly) { 'Container and Kubernetes Phase 0 Kubernetes-only regression suite' } else { 'Container and Kubernetes Phase 0 regression suite' }
        runId = $script:RunId
        sourceRevision = $script:SourceInfo.revision
        sourceSnapshotSha256 = $script:SourceInfo.snapshotSha256
        state = 'PASS'
        passedGates = $script:Results.Count
        results = @($script:Results)
    }
    Write-Output ($summary | ConvertTo-Json -Depth 12)
}
catch {
    $message = $_.Exception.Message
    Write-Phase0Result -Name 'Phase 0 regression harness' -State 'FAIL' -Evidence ([pscustomobject]@{ error = $message })
    throw
}
finally {
    Invoke-Cleanup
}
