<#
.SYNOPSIS
  Reports the router's WAN address, the public egress address, whether the
  line is behind carrier NAT, and whether inbound HTTP/HTTPS is reachable
  from the internet.

.DESCRIPTION
  WAN address  : read from the router over UPnP, no login required.
  Egress       : read from an external HTTP service, cross-checked via DNS.
  CGNAT verdict: compares WAN against egress and classifies the WAN range.
  Ownership    : looks up the ASN of both addresses. If the WAN belongs to a
                 network other than the ISP's, the internet cannot route it to
                 this line.
  Reachability : an external fetcher (r.jina.ai) requests the public address.
                 This is only meaningful when a local process is listening on
                 the port. If nothing is, the script reports NOT TESTED rather
                 than a false "unreachable" (a closed port looks identical to a
                 blocked one from outside).

.PARAMETER RouterIp
  Router LAN address. Defaults to 192.168.1.1.

.PARAMETER ProbeTimeoutSec
  Timeout for the external reachability fetch. Defaults to 30 seconds.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-router-wan.ps1
#>
param(
    [string]$RouterIp = "192.168.1.1",
    [int]$ProbeTimeoutSec = 30
)

$ErrorActionPreference = "Continue"

function Get-RouterWanIp {
    param([string]$Address)

    $udp = New-Object Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = 2000
    try {
        # Unicast: this router ignores multicast SSDP.
        $search = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: ssdp:all`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($search)
        $target = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($Address), 1900)
        [void]$udp.Send($bytes, $bytes.Length, $target)

        $responses = @()
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $responses += [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$remote))
            }
            catch {
                break
            }
        }
    }
    finally {
        $udp.Close()
    }

    if ($responses.Count -eq 0) {
        throw "No UPnP answer from $Address. Is UPnP enabled on the router?"
    }

    $location = ([regex]::Match($responses[0], '(?im)^LOCATION:\s*(\S+)')).Groups[1].Value.Trim()
    $description = [xml](Invoke-WebRequest -Uri $location -UseBasicParsing -TimeoutSec 6).Content
    $service = $description.SelectNodes("//*[local-name()='service']") |
        Where-Object { $_.SelectSingleNode("*[local-name()='serviceType']").InnerText -match 'WANIPConnection' } |
        Select-Object -First 1

    if (-not $service) {
        throw "No WANIPConnection service in the router description."
    }

    $serviceType = $service.SelectSingleNode("*[local-name()='serviceType']").InnerText
    $controlUrl = (New-Object Uri(([uri]$location), $service.SelectSingleNode("*[local-name()='controlURL']").InnerText)).AbsoluteUri

    $soap = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetExternalIPAddress xmlns:u="' + $serviceType + '"/></s:Body></s:Envelope>'

    $response = Invoke-WebRequest -Uri $controlUrl -Method Post `
        -Headers @{ SOAPAction = '"' + $serviceType + '#GetExternalIPAddress"' } `
        -ContentType 'text/xml; charset="utf-8"' `
        -Body $soap -UseBasicParsing -TimeoutSec 6

    $addressNode = ([xml]$response.Content).SelectSingleNode("//*[local-name()='NewExternalIPAddress']")
    if (-not $addressNode) {
        throw "The router did not return an external IP address."
    }

    $addressNode.InnerText
}

function Get-PublicEgress {
    $http = (curl.exe -4 -s --max-time 8 https://api.ipify.org) -join ""
    if ($http) { $http = $http.Trim() }

    $dns = $null
    try {
        $answer = Resolve-DnsName -Name myip.opendns.com -Server 208.67.222.222 -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1
        if ($answer) { $dns = $answer.IPAddress }
    }
    catch { }

    [pscustomobject]@{ Http = $http; Dns = $dns }
}

function Test-PrivateAddress {
    param([string]$Address)

    $bytes = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $true }
    if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $true }
    return $false
}

function Get-AsnInfo {
    param([string]$Address)

    try {
        $result = Invoke-RestMethod -Uri ("https://stat.ripe.net/data/prefix-overview/data.json?resource=" + $Address) -TimeoutSec 10
        $asns = @($result.data.asns)
        if ($asns.Count -gt 0) {
            return ("AS" + $asns[0].asn + " " + $asns[0].holder)
        }
        return "not announced"
    }
    catch {
        return "lookup failed"
    }
}

function Test-PortListening {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$listeners
}

function Test-InboundReachability {
    param(
        [string]$Address,
        [int]$Port,
        [int]$TimeoutSec
    )

    $scheme = if ($Port -eq 443) { "https" } else { "http" }
    $target = $scheme + "://" + $Address + "/"
    $probeUrl = "https://r.jina.ai/" + $target

    $output = (curl.exe -s --max-time $TimeoutSec $probeUrl) -join "`n"
    if (-not $output) {
        return [pscustomobject]@{ Status = "unknown"; Detail = "external probe returned nothing" }
    }
    if ($output -match 'TimeoutError') {
        return [pscustomobject]@{ Status = "unreachable"; Detail = "external fetch timed out (filtered, refused, or no route)" }
    }
    return [pscustomobject]@{ Status = "reachable"; Detail = "external fetch returned content" }
}

# ---- collect ---------------------------------------------------------------

$wan = $null
$wanError = $null
try {
    $wan = Get-RouterWanIp -Address $RouterIp
}
catch {
    $wanError = $_.Exception.Message
}

$egress = Get-PublicEgress
$egressAddress = if ($egress.Http) { $egress.Http } else { $egress.Dns }

# ---- report ----------------------------------------------------------------

Write-Output ("Router WAN (UPnP) : " + $(if ($wan) { $wan } else { "unavailable - $wanError" }))
Write-Output ("Public egress     : " + $(if ($egress.Http) { $egress.Http } else { "unavailable" }))
Write-Output ("Egress (DNS check): " + $(if ($egress.Dns) { $egress.Dns } else { "unavailable" }))
Write-Output ""

$carrierNat = $false
if ($wan) {
    $wanIsPrivate = Test-PrivateAddress -Address $wan
    $sameAddress = ($egressAddress -and $wan -eq $egressAddress)

    if ($sameAddress) {
        Write-Output "Carrier NAT       : NO - the WAN address equals the public egress"
    }
    elseif ($wanIsPrivate) {
        $carrierNat = $true
        Write-Output "Carrier NAT       : YES - the WAN address is private or RFC 6598 (100.64.0.0/10)"
    }
    else {
        $carrierNat = $true
        Write-Output "Carrier NAT       : YES - the WAN address differs from the public egress, so the router is not the public endpoint"
    }
    Write-Output ("WAN range         : " + $(if ($wanIsPrivate) { "private / shared (not globally routable)" } else { "public per RFC (not RFC1918 or 100.64.0.0/10)" }))

    $wanAsn = Get-AsnInfo -Address $wan
    $egressAsn = if ($egressAddress) { Get-AsnInfo -Address $egressAddress } else { "unavailable" }
    Write-Output ("WAN ASN           : " + $wanAsn)
    Write-Output ("Egress ASN        : " + $egressAsn)

    if ($wanAsn -notmatch 'lookup failed' -and $egressAsn -notmatch 'lookup failed' -and $wanAsn -ne $egressAsn) {
        Write-Output "WAN ownership     : WARNING - the WAN address is not in your ISP's address space; the internet routes it to a different network, not to this line"
    }
    Write-Output ""
}

if ($egressAddress) {
    foreach ($port in @(80, 443)) {
        $label = "Inbound :$port".PadRight(18) + ": "
        if (-not (Test-PortListening -Port $port)) {
            Write-Output ($label + "NOT TESTED - nothing is listening locally on this port (start the web server/Caddy to test)")
        }
        else {
            $probe = Test-InboundReachability -Address $egressAddress -Port $port -TimeoutSec $ProbeTimeoutSec
            Write-Output ($label + $probe.Status.ToUpper() + " - " + $probe.Detail)
        }
    }
}
else {
    Write-Output "Inbound           : NOT TESTED - no public egress address could be determined"
}

if ($carrierNat) {
    Write-Output ""
    Write-Output "Conclusion        : the line has no public IPv4 endpoint; inbound connections cannot reach this router until the ISP provisions a routed static address"
}
