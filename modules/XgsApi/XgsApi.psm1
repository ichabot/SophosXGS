<#
    XgsApi - gemeinsame Funktionen fuer die Sophos Firewall XML-API (XGS / SFOS).
    Wird von allen Tools unter .\tools eingebunden.

    Laeuft unter Windows PowerShell 5.1 und PowerShell 7.

    Kurzueberblick:
        Start-XgsLog            Logdatei fuer die Sitzung festlegen
        Write-XgsLog            Zeile auf Konsole + Logdatei schreiben
        Connect-XgsFirewall     Zugangsdaten setzen und Login testen
        Disconnect-XgsFirewall  Zugangsdaten aus dem Speicher entfernen
        Invoke-XgsRequest       Beliebigen Request-Body senden, Antwort als [xml]
        Get-XgsObject           <Get><Tag/></Get> und Knoten zurueckgeben
        Set-XgsObject           Objekte per <Set operation="add|update"> senden, Ergebnis je Objekt
        New-XgsRequestXml       Request-XML erzeugen (ohne Login z. B. fuer DryRun)
        ConvertTo-XgsXmlText    Text XML-sicher maskieren
        Test-XgsIPv4 / ConvertTo-XgsNetmask   Validierungshelfer
#>

Set-StrictMode -Version Latest

$script:XgsSession = $null
$script:XgsLogFile = $null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Start-XgsLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $script:XgsLogFile = $Path
    Write-XgsLog "Log: $Path"
}

function Write-XgsLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:XgsLogFile) { Add-Content -Path $script:XgsLogFile -Value $line -Encoding UTF8 }
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# XML-Helfer
# ---------------------------------------------------------------------------

function ConvertTo-XgsXmlText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-XgsRequestXml {
    <#
        Baut <Request> um den Body. Mit -NoLogin ohne Zugangsdaten (DryRun, Ablage).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Body = '',
        [switch]$NoLogin
    )
    $login = ''
    if (-not $NoLogin) {
        if (-not $script:XgsSession) { throw 'Keine Sitzung. Zuerst Connect-XgsFirewall aufrufen.' }
        $u = ConvertTo-XgsXmlText $script:XgsSession.User
        $p = ConvertTo-XgsXmlText $script:XgsSession.Credential.GetNetworkCredential().Password
        $login = "  <Login><Username>$u</Username><Password>$p</Password></Login>`n"
    }
    return "<Request>`n$login$Body`n</Request>"
}

# ---------------------------------------------------------------------------
# Verbindung
# ---------------------------------------------------------------------------

function Initialize-XgsTls {
    param([bool]$SkipCertificateCheck)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($SkipCertificateCheck -and -not ('XgsTrustAllCertsPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class XgsTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    if ($SkipCertificateCheck) { [Net.ServicePointManager]::CertificatePolicy = New-Object XgsTrustAllCertsPolicy }
}

function Connect-XgsFirewall {
    <#
    .SYNOPSIS
        Legt die Sitzung an und testet den Login.
    .PARAMETER Firewall
        IP oder Hostname, optional mit :Port (Standard 4444).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$SkipCertificateCheck,
        [int]$TimeoutSec = 300
    )
    $hostPart = if ($Firewall -match ':\d+$') { $Firewall } else { "${Firewall}:4444" }
    if (-not $Credential) { $Credential = Get-Credential -Message "API-Benutzer fuer $hostPart" }
    if (-not $Credential) { throw 'Keine Zugangsdaten angegeben.' }

    Initialize-XgsTls -SkipCertificateCheck:$SkipCertificateCheck

    $script:XgsSession = [pscustomobject]@{
        Url                  = "https://$hostPart/webconsole/APIController"
        User                 = $Credential.UserName
        Credential           = $Credential
        SkipCertificateCheck = [bool]$SkipCertificateCheck
        TimeoutSec           = $TimeoutSec
    }

    Write-XgsLog "Verbinde mit $($script:XgsSession.Url) als $($script:XgsSession.User)"
    try { [void](Invoke-XgsRequest -Body '') }
    catch { $script:XgsSession = $null; throw }
    Write-XgsLog 'Login erfolgreich' 'OK'
}

function Disconnect-XgsFirewall {
    $script:XgsSession = $null
}

function Invoke-XgsRequest {
    <#
    .SYNOPSIS
        Sendet einen Request-Body (alles innerhalb von <Request> ausser <Login>)
        und liefert die Antwort als [xml]. Wirft bei Verbindungs- oder Loginfehler.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Body = '')

    if (-not $script:XgsSession) { throw 'Keine Sitzung. Zuerst Connect-XgsFirewall aufrufen.' }
    $s = $script:XgsSession

    $p = @{
        Uri             = $s.Url
        Method          = 'Post'
        Body            = @{ reqxml = (New-XgsRequestXml -Body $Body) }
        ContentType     = 'application/x-www-form-urlencoded'
        UseBasicParsing = $true
        TimeoutSec      = $s.TimeoutSec
    }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $s.SkipCertificateCheck) { $p.SkipCertificateCheck = $true }

    try { $resp = Invoke-WebRequest @p }
    catch { throw "API nicht erreichbar ($($s.Url)): $($_.Exception.Message)" }

    try { $xml = [xml]$resp.Content }
    catch { throw "Antwort der Firewall ist kein gueltiges XML: $($resp.Content)" }

    $node   = $xml.SelectSingleNode('/Response/Login/status')
    $status = if ($node) { $node.InnerText } else { '' }
    if ($status -notmatch 'Successful') {
        $st = $xml.SelectSingleNode('/Response/Status')
        $detail = if ($st) { $st.InnerText } else { $xml.OuterXml }
        throw "Login fehlgeschlagen: $status $detail"
    }
    return $xml
}

# ---------------------------------------------------------------------------
# Objekte lesen / schreiben
# ---------------------------------------------------------------------------

function Get-XgsObject {
    <#
    .SYNOPSIS
        Liest alle Objekte eines Typs, z. B. VLAN, Zone, Interface, LAG, IPHost.
    .PARAMETER Raw
        Gibt die komplette Antwort als [xml] zurueck statt der einzelnen Knoten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tag,
        [switch]$Raw
    )
    $xml = Invoke-XgsRequest -Body "  <Get><$Tag></$Tag></Get>"
    if ($Raw) { return $xml }
    return @($xml.SelectNodes("/Response/$Tag"))
}

function Get-XgsResultMap {
    <#
        Wertet die Antwort eines Set-Requests aus. Ergebnis je Objekt per
        transactionid (Fallback: Reihenfolge der uebergebenen Keys).
    #>
    param([xml]$Response, [string]$Tag, [string[]]$Keys)
    $map   = @{}
    $nodes = @($Response.SelectNodes("/Response/$Tag"))
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $n   = $nodes[$i]
        $key = $n.GetAttribute('transactionid')
        if ([string]::IsNullOrEmpty($key) -and $i -lt $Keys.Count) { $key = $Keys[$i] }
        $st  = $n.SelectSingleNode('Status')
        $map[$key] = [pscustomobject]@{
            Code    = if ($st) { $st.GetAttribute('code') } else { '' }
            Message = if ($st) { $st.InnerText } else { $n.InnerText }
        }
    }
    return $map
}

function Set-XgsObject {
    <#
    .SYNOPSIS
        Sendet Objekt-XML-Bloecke per <Set operation="..."> in Batches und
        liefert je Objekt Key, Ok, Code und Message.
    .PARAMETER Items
        Objekte mit den Eigenschaften Key (eindeutig, landet in transactionid)
        und Xml (der fertige Block, z. B. <VLAN transactionid="KEY">...</VLAN>).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][object[]]$Items,
        [ValidateSet('add', 'update')][string]$Operation = 'add',
        [ValidateRange(1, 100)][int]$BatchSize = 10
    )
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
        $chunk = @($Items[$i..([Math]::Min($i + $BatchSize, $Items.Count) - 1)])
        Write-XgsLog "Sende $Tag $($i + 1)-$($i + $chunk.Count) von $($Items.Count)"
        $body = ($chunk | ForEach-Object { $_.Xml }) -join "`n"
        $resp = Invoke-XgsRequest -Body "  <Set operation=`"$Operation`">`n$body`n  </Set>"
        $res  = Get-XgsResultMap -Response $resp -Tag $Tag -Keys @($chunk | ForEach-Object { $_.Key })
        foreach ($c in $chunk) {
            $r = $res[$c.Key]
            $out.Add([pscustomobject]@{
                Key     = $c.Key
                Ok      = [bool]($r -and $r.Code -eq '200')
                Code    = if ($r) { $r.Code } else { '' }
                Message = if ($r) { $r.Message } else { 'keine Rueckmeldung' }
            })
        }
    }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------
# Validierung
# ---------------------------------------------------------------------------

function Test-XgsIPv4 {
    param([string]$Value)
    if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
    return $true
}

function ConvertTo-XgsNetmask {
    # Akzeptiert 255.255.255.0, 24 oder /24 und liefert die Punktnotation oder $null
    param([string]$Value)
    $v = $Value.Trim().TrimStart('/')
    if ($v -match '^\d{1,2}$') {
        $p = [int]$v
        if ($p -lt 1 -or $p -gt 32) { return $null }
        $bits = ('1' * $p).PadRight(32, '0')
        return (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
    }
    if (-not (Test-XgsIPv4 $v)) { return $null }
    $bin = ($v.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    if ($bin -notmatch '^1+0*$') { return $null }
    return $v
}

function Import-XgsCsv {
    <#
        CSV einlesen mit automatischer Erkennung von ';' oder ','.
        Leere Zeilen und Zeilen, die mit # beginnen, werden ignoriert.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$RequiredColumns = @())
    if (-not (Test-Path $Path)) { throw "CSV nicht gefunden: $Path" }
    $header = Get-Content -Path $Path -TotalCount 1
    $delim  = if ($header.Split(';').Count -ge $header.Split(',').Count) { ';' } else { ',' }
    $rows = @(Import-Csv -Path $Path -Delimiter $delim -Encoding UTF8 | Where-Object {
            $vals = @($_.PSObject.Properties | ForEach-Object { [string]$_.Value })
            ($vals -join '').Trim() -ne '' -and -not $vals[0].Trim().StartsWith('#')
        })
    if ($rows.Count -gt 0 -and $RequiredColumns.Count -gt 0) {
        $cols    = $rows[0].PSObject.Properties.Name
        $missing = @($RequiredColumns | Where-Object { $cols -notcontains $_ })
        if ($missing.Count) { throw "In der CSV fehlen Spalten: $($missing -join ', ')" }
    }
    return , $rows
}

Export-ModuleMember -Function Start-XgsLog, Write-XgsLog, ConvertTo-XgsXmlText, New-XgsRequestXml,
    Connect-XgsFirewall, Disconnect-XgsFirewall, Invoke-XgsRequest, Get-XgsObject, Get-XgsResultMap,
    Set-XgsObject, Test-XgsIPv4, ConvertTo-XgsNetmask, Import-XgsCsv
