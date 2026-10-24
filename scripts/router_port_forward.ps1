# Manage the Airtel Zyxel gateway's NAT port-forwarding table.
#
# The router's admin interface is an undocumented CGI surface. This script
# wraps the three things an operator needs: see the table, remove a rule, and
# put one back. It reads the router credentials from an out-of-repository
# secrets file, so no credential is ever committed.
#
# WHY THIS EXISTS
#
# The public ingress path is Caddy on 443/80, fronting the Rust origin on
# 127.0.0.1:8000. The origin must NOT be forwarded from the internet: a
# forwarded :8000 exposes the whole API over plain HTTP, bypassing TLS
# entirely. A forward for 8000 existed from 2026-10-19 and was removed on
# 2026-10-20 with this script.
#
# WHY curl.exe AND NOT Invoke-WebRequest
#
# This firmware emits malformed HTTP response headers on some endpoints (bare
# CR where CRLF is expected). .NET's HttpWebRequest rejects that as a
# protocol violation; curl tolerates it. The login POST and the list GET both
# work under curl, so the whole script uses it and keeps the session in a
# cookie jar.
#
# DELNUM IS ZERO-BASED
#
# The router's own JavaScript calls deleteClick(0) for the FIRST rule in the
# list. The table is also displayed with 1-based row numbers, so the number in
# the "#" column is NOT the index to delete. Getting this wrong deletes the
# wrong rule - and on this router that would take the HTTPS rule down and
# with it the public site. This script therefore identifies a rule by its
# CONTENT (service name and port) and only then acts on the index, and it
# re-reads the table afterwards to confirm the other rules survived.
#
# Usage:
#   .\router_port_forward.ps1 -Action List
#   .\router_port_forward.ps1 -Action Remove -Description MediaServer -Confirm
#   .\router_port_forward.ps1 -Action Add -Description MediaServer `
#       -ExternalPort 8000 -InternalPort 8000 -InternalClient 192.168.1.16 -Confirm

param(
    [ValidateSet("List", "Remove", "Add")]
    [string]$Action = "List",

    # Service name as shown in the router's table.
    [string]$Description,

    # Used to disambiguate when more than one rule shares a name.
    [int]$ExternalPort = 0,

    [int]$InternalPort = 0,
    [string]$Protocol = "TCP",
    [string]$InternalClient = "192.168.1.16",

    [string]$RouterIp = "192.168.1.1",

    # Credentials live outside the repository on purpose.
    [string]$SecretFile = "D:\Airtel xstream fiber\secret.md",

    # Required for Remove and Add. Without it the script only reports.
    [switch]$Confirm
)

$ErrorActionPreference = "Stop"
$script:CookieJar = Join-Path $env:TEMP ("zyxel_pf_" + [guid]::NewGuid().ToString("N") + ".txt")

# --- helpers -----------------------------------------------------------------

function Get-SecretValue([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { throw "Secret file not found: $Path" }
    $content = Get-Content $Path -Raw
    $m = [regex]::Match($content, "(?im)^\s*$([regex]::Escape($Key))\s*[:=]\s*(.+?)\s*$")
    if (-not $m.Success) { throw "Key '$Key' not found in $Path" }
    return $m.Groups[1].Value.Trim()
}

function Get-Md5Hex([string]$Text) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::GetEncoding("latin1").GetBytes($Text)
    return (-join ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }))
}

function Invoke-Curl {
    param([string]$Url, [hashtable]$Post = $null)
    $args = @("-s", "--max-time", "30", "-b", $script:CookieJar, "-c", $script:CookieJar)
    if ($Post) {
        $args += @("-X", "POST")
        foreach ($k in $Post.Keys) {
            $args += @("-d", ("{0}={1}" -f $k, [uri]::EscapeDataString([string]$Post[$k])))
        }
    }
    $args += $Url
    $out = & curl.exe @args
    if ($LASTEXITCODE -ne 0) { throw "curl failed (exit $LASTEXITCODE) for $Url" }
    return ($out -join "`n")
}

function Invoke-RouterLogin {
    $user = Get-SecretValue $SecretFile "username"
    $pass = Get-SecretValue $SecretFile "password"

    $loginUrl = "http://$RouterIp/cgi-bin/login_advance.cgi"
    $page = Invoke-Curl -Url $loginUrl
    $sidMatch = [regex]::Match($page, "var sid = '([^']+)'")
    if (-not $sidMatch.Success) { throw "Could not read the session id from the login page." }
    $sid = $sidMatch.Groups[1].Value

    # encodeURIComponent, with LOWERCASE hex escapes - the router hashes the
    # percent-encoded password, and the escape hex case matters.
    $enc = [System.Uri]::EscapeDataString($pass)
    $enc = [regex]::Replace($enc, '%[0-9A-F]{2}', { param($m) $m.Value.ToLower() })
    $hash = Get-Md5Hex "$enc`:$sid"

    Invoke-Curl -Url $loginUrl -Post @{
        Loginuser          = $user
        LoginPasswordValue = $hash
        LoginSidValue      = $sid
        submitValue        = "1"
        Prestige_Login     = "Login"
        fake_username      = ""
        fake_pass          = ""
    } | Out-Null

    if (-not (Test-Path $script:CookieJar)) { throw "Router login failed (no cookie jar was written)." }
    $jar = Get-Content $script:CookieJar -Raw
    if ($jar -notmatch "COOKIE_SESSION_KEY") { throw "Router login failed (no session cookie)." }
}

function Get-PortForwardRules {
    $html = Invoke-Curl -Url "http://$RouterIp/cgi-bin/port_forwarding_list.cgi"
    $rules = @()
    $index = 0
    foreach ($row in [regex]::Matches($html, '(?s)<tr[^>]*align="center"[^>]*>(.*?)</tr>')) {
        $cells = [regex]::Matches($row.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>') |
            ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>', '' -replace '\s+', ' ').Trim() }
        if ($cells.Count -lt 8) { continue }
        if ($cells[0] -eq "#") { continue }   # header row
        $rules += [pscustomobject]@{
            Index       = $index          # zero-based deleteClick index
            RowNumber   = $cells[0]       # the 1-based number shown in the table
            Active      = ($cells[1] -notmatch 'i_active_off')
            Description = $cells[2]
            ExtStart    = $cells[3]
            ExtEnd      = $cells[4]
            IntStart    = $cells[5]
            IntEnd      = $cells[6]
            ServerIP    = $cells[7]
        }
        $index++
    }
    return $rules
}

function Show-Rules($Rules) {
    if (-not $Rules -or $Rules.Count -eq 0) {
        Write-Host "  (no port forwarding rules)" -ForegroundColor DarkGray
        return
    }
    Write-Host ("  {0,-4} {1,-7} {2,-16} {3,-12} {4,-12} {5}" -f "idx", "active", "description", "external", "internal", "server ip")
    Write-Host ("  " + ("-" * 72))
    foreach ($r in $Rules) {
        Write-Host ("  {0,-4} {1,-7} {2,-16} {3,-12} {4,-12} {5}" -f `
            $r.Index, $(if ($r.Active) { "on" } else { "off" }), $r.Description, `
            "$($r.ExtStart)-$($r.ExtEnd)", "$($r.IntStart)-$($r.IntEnd)", $r.ServerIP)
    }
}

# --- run ---------------------------------------------------------------------

try {
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     Zyxel Router Port Forwarding Management        " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    Invoke-RouterLogin
    Write-Host "Authenticated to the router at $RouterIp." -ForegroundColor Green

    $before = Get-PortForwardRules
    Write-Host "`nCurrent rules:" -ForegroundColor Cyan
    Show-Rules $before

    if ($Action -eq "List") {
        Write-Host "`nDone." -ForegroundColor Green
        exit 0
    }

    if ($Action -eq "Remove") {
        if (-not $Description) { throw "Remove requires -Description." }

        $targets = @($before | Where-Object {
            $_.Description -eq $Description -and ($ExternalPort -eq 0 -or $_.ExtStart -eq "$ExternalPort")
        })
        if ($targets.Count -eq 0) { throw "No rule named '$Description' matches. Nothing to remove." }
        if ($targets.Count -gt 1) { throw "More than one rule named '$Description' matches. Add -ExternalPort to disambiguate." }

        $target = $targets[0]
        Write-Host "`nMatched rule:" -ForegroundColor Cyan
        Write-Host ("  index={0} row={1} description={2} external={3}-{4} server={5}" -f `
            $target.Index, $target.RowNumber, $target.Description, $target.ExtStart, $target.ExtEnd, $target.ServerIP)

        if (-not $Confirm) {
            Write-Host "`nDRY RUN - nothing was changed. Re-run with -Confirm to remove it." -ForegroundColor Yellow
            exit 0
        }

        # Every OTHER rule must survive. Remember them so we can check afterwards.
        $survivors = @($before | Where-Object { $_.Index -ne $target.Index })

        Write-Host "`nRemoving it..." -ForegroundColor Yellow
        Invoke-Curl -Url "http://$RouterIp/cgi-bin/portForwarding.cgi" -Post @{
            reloadFlag    = "1"
            delFlag       = "1"
            delnum        = "$($target.Index)"
            editFlag      = "0"
            NAT_WAN_Index = "11"
            NAT_EXT_Index = "0"
            xDSL          = "adsl"
            VDSLIndex     = "0"
            VDSLIndexExt  = "0"
        } | Out-Null

        Start-Sleep -Seconds 2

        $after = Get-PortForwardRules
        Write-Host "`nRules after the change:" -ForegroundColor Cyan
        Show-Rules $after

        $stillThere = @($after | Where-Object { $_.Description -eq $target.Description -and $_.ExtStart -eq $target.ExtStart })
        if ($stillThere.Count -gt 0) { throw "The rule '$Description' is still present. The delete did not take effect." }
        foreach ($s in $survivors) {
            $found = @($after | Where-Object { $_.Description -eq $s.Description -and $_.ExtStart -eq $s.ExtStart })
            if ($found.Count -eq 0) { throw "Rule '$($s.Description)' ($($s.ExtStart)) did not survive. Restore from the NVRAM backup." }
        }

        Write-Host "`nRemoved '$($target.Description)' (external $($target.ExtStart)). All other rules survived." -ForegroundColor Green
        exit 0
    }

    if ($Action -eq "Add") {
        if (-not $Description) { throw "Add requires -Description." }
        if ($ExternalPort -le 0 -or $InternalPort -le 0) { throw "Add requires -ExternalPort and -InternalPort." }

        # The add form's field names, taken from the router's own doSave().
        $form = Invoke-Curl -Url "http://$RouterIp/cgi-bin/portForwarding_add.cgi"
        $fields = @{}
        [regex]::Matches($form, '(?is)<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"') | ForEach-Object {
            $fields[$_.Groups[1].Value] = $_.Groups[2].Value
        }
        Write-Host "Add form fields discovered: $(($fields.Keys | Sort-Object) -join ', ')" -ForegroundColor DarkGray

        # The router's doSave() sets ruleindex to the CURRENT rule count, which
        # is what makes the submission an append rather than an overwrite of
        # an existing rule. Sending an in-range index here would silently
        # rewrite a rule instead of adding one.
        $ruleIndex = $before.Count
        Write-Host "New rule will be appended at index $ruleIndex (current rule count)." -ForegroundColor DarkGray

        $body = @{
            reloadFlag        = "1"
            editFlag          = "1"
            ruleindex         = "$ruleIndex"
            PortRule_Active   = "Yes"
            start_port        = "$InternalPort"
            end_port          = "$InternalPort"
            appName           = $Description
            Addr              = $InternalClient
            PortRule_Protocol = $Protocol
            oStart            = "$ExternalPort"
            oEnd              = "$ExternalPort"
            NAT_VCIndex       = "1"
            NAT_WAN_Index     = "11"
            NAT_EXT_Index     = "0"
            xDSL              = "adsl"
            VDSLIndex         = "0"
            VDSLIndexExt      = "0"
        }
        foreach ($k in $fields.Keys) {
            if (-not $body.ContainsKey($k)) { $body[$k] = $fields[$k] }
        }

        if (-not $Confirm) {
            Write-Host "`nDRY RUN - nothing was changed. Re-run with -Confirm to add the rule." -ForegroundColor Yellow
            Write-Host "  description=$Description external=$ExternalPort internal=$InternalPort protocol=$Protocol client=$InternalClient" -ForegroundColor DarkGray
            exit 0
        }

        Invoke-Curl -Url "http://$RouterIp/cgi-bin/portForwarding.cgi" -Post $body | Out-Null
        Start-Sleep -Seconds 2

        $after = Get-PortForwardRules
        Write-Host "`nRules after the change:" -ForegroundColor Cyan
        Show-Rules $after

        $found = @($after | Where-Object { $_.Description -eq $Description -and $_.ExtStart -eq "$ExternalPort" })
        if ($found.Count -eq 0) { throw "The rule was not created. Check the add form's field names." }

        # Every pre-existing rule must have survived.
        foreach ($s in $before) {
            $still = @($after | Where-Object { $_.Description -eq $s.Description -and $_.ExtStart -eq $s.ExtStart })
            if ($still.Count -eq 0) { throw "Rule '$($s.Description)' ($($s.ExtStart)) did not survive the add." }
        }

        Write-Host "`nCreated '$Description' (external $ExternalPort -> $InternalClient`:$InternalPort). All previous rules survived." -ForegroundColor Green
        exit 0
    }
} finally {
    if (Test-Path $script:CookieJar) { Remove-Item $script:CookieJar -Force -ErrorAction SilentlyContinue }
}
