<#
.SYNOPSIS
    Legt VLAN-Interfaces (und optional fehlende Zonen) per XML-API auf einer
    Sophos Firewall (XGS / SFOS) an. Datenquelle ist eine CSV-Datei.

.DESCRIPTION
    Ablauf:
      1. CSV einlesen und pruefen (Pflichtfelder, VLAN-ID, IP, Netzmaske, Dubletten)
      2. Login an der API testen
      3. Vorhandene Zonen abfragen, fehlende Zonen melden bzw. anlegen (-CreateMissingZones)
      4. Vorhandene VLANs abfragen, bereits existierende werden uebersprungen
      5. Neue VLANs blockweise anlegen und Ergebnis je VLAN ausgeben

    Mit -DryRun wird keine Verbindung aufgebaut. Das Skript prueft nur die CSV
    und schreibt die erzeugten Request-XMLs (ohne Zugangsdaten) nach .\output.

.PARAMETER Firewall
    Hostname oder IP der Firewall, optional mit Port (Standard 4444).

.PARAMETER CsvPath
    Pfad zur CSV-Datei. Standard: vlans.csv im Tool-Ordner.

.PARAMETER Credential
    API-Benutzer. Ohne Angabe wird interaktiv abgefragt.

.PARAMETER DryRun
    Nur pruefen und XML erzeugen, nichts an die Firewall senden.

.PARAMETER CreateMissingZones
    Fehlende Zonen anlegen (Typ aus CSV-Spalte ZoneType, Standard LAN).

.PARAMETER BatchSize
    Anzahl VLANs pro API-Request. Standard: 10

.PARAMETER SkipCertificateCheck
    Zertifikat der Firewall nicht pruefen (selbstsigniertes Admin-Zertifikat).

.PARAMETER DumpExisting
    Speichert vorhandene VLAN-, Zonen-, Interface- und LAG-Objekte als XML
    nach .\output und beendet sich danach.

.EXAMPLE
    .\Invoke-XgsVlanBulk.ps1 -DryRun

.EXAMPLE
    .\Invoke-XgsVlanBulk.ps1 -Firewall 192.168.1.1 -SkipCertificateCheck -CreateMissingZones
#>
[CmdletBinding()]
param(
    [string]$Firewall,
    [string]$CsvPath = (Join-Path $PSScriptRoot 'vlans.csv'),
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$DryRun,
    [switch]$CreateMissingZones,
    [ValidateRange(1, 100)][int]$BatchSize = 10,
    [switch]$SkipCertificateCheck,
    [switch]$DumpExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ExitCode = 0

Import-Module (Join-Path $PSScriptRoot '..\..\modules\XgsApi\XgsApi.psm1') -Force -DisableNameChecking

$OutDir = Join-Path $PSScriptRoot 'output'
$LogDir = Join-Path $PSScriptRoot 'logs'
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
Start-XgsLog -Path (Join-Path $LogDir "run-$Stamp.log")

# ---------------------------------------------------------------------------
# CSV einlesen und pruefen
# ---------------------------------------------------------------------------

function Import-VlanCsv {
    param([string]$Path)

    $required = 'Name', 'VLANID', 'Interface', 'Zone', 'IPAddress', 'Netmask'
    $rows     = Import-XgsCsv -Path $Path -RequiredColumns $required
    $errors   = New-Object System.Collections.Generic.List[string]
    $vlans    = New-Object System.Collections.Generic.List[object]
    $line     = 1

    foreach ($r in $rows) {
        $line++
        $get = { param($n) if ($r.PSObject.Properties.Name -contains $n -and $null -ne $r.$n) { ([string]$r.$n).Trim() } else { '' } }

        $name  = & $get 'Name'
        $idRaw = & $get 'VLANID'
        $iface = & $get 'Interface'
        $zone  = & $get 'Zone'
        $ip    = & $get 'IPAddress'
        $maskR = & $get 'Netmask'
        $zType = (& $get 'ZoneType').ToUpper()
        if ($zType -eq '') { $zType = 'LAN' }

        foreach ($f in $required) { if ((& $get $f) -eq '') { $errors.Add("Zeile ${line}: Feld '$f' ist leer") } }

        $id = 0
        if ($idRaw -ne '' -and (-not [int]::TryParse($idRaw, [ref]$id) -or $id -lt 1 -or $id -gt 4094)) {
            $errors.Add("Zeile ${line}: VLANID '$idRaw' ungueltig (1-4094)")
        }
        if ($ip -ne '' -and -not (Test-XgsIPv4 $ip)) { $errors.Add("Zeile ${line}: IPAddress '$ip' ungueltig") }
        $mask = if ($maskR -ne '') { ConvertTo-XgsNetmask $maskR } else { $null }
        if ($maskR -ne '' -and -not $mask) { $errors.Add("Zeile ${line}: Netmask '$maskR' ungueltig") }
        if ($zType -notin 'LAN', 'DMZ') { $errors.Add("Zeile ${line}: ZoneType '$zType' ungueltig (LAN oder DMZ)") }
        if ($name.Length -gt 50) { $errors.Add("Zeile ${line}: Name '$name' laenger als 50 Zeichen") }

        $vlans.Add([pscustomobject]@{
            Line      = $line
            Name      = $name
            VLANID    = $id
            Interface = $iface
            Hardware  = "$iface.$id"
            Zone      = $zone
            ZoneType  = $zType
            IPAddress = $ip
            Netmask   = $mask
        })
    }

    $vlans | Group-Object Hardware | Where-Object Count -gt 1 | ForEach-Object {
        $errors.Add("VLAN $($_.Name) mehrfach in der CSV (Zeilen $(($_.Group.Line) -join ', '))")
    }
    $vlans | Group-Object Name | Where-Object { $_.Name -ne '' -and $_.Count -gt 1 } | ForEach-Object {
        $errors.Add("Name '$($_.Name)' mehrfach in der CSV (Zeilen $(($_.Group.Line) -join ', '))")
    }
    $vlans | Where-Object IPAddress | Group-Object IPAddress | Where-Object Count -gt 1 | ForEach-Object {
        $errors.Add("IP $($_.Name) mehrfach in der CSV (Zeilen $(($_.Group.Line) -join ', '))")
    }
    $vlans | Where-Object Zone | Group-Object Zone | ForEach-Object {
        $types = @($_.Group.ZoneType | Select-Object -Unique)
        if ($types.Count -gt 1) { $errors.Add("Zone '$($_.Name)' hat unterschiedliche ZoneType-Werte ($($types -join ', '))") }
    }

    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-XgsLog $_ 'ERROR' }
        throw "CSV enthaelt $($errors.Count) Fehler. Abbruch."
    }
    return , $vlans.ToArray()
}

# ---------------------------------------------------------------------------
# XML-Bausteine
# ---------------------------------------------------------------------------

function New-VlanXml {
    param($v)
    $x = { param($s) ConvertTo-XgsXmlText $s }
@"
    <VLAN transactionid="$(& $x $v.Hardware)">
      <Zone>$(& $x $v.Zone)</Zone>
      <Interface>$(& $x $v.Interface)</Interface>
      <Hardware>$(& $x $v.Hardware)</Hardware>
      <Name>$(& $x $v.Name)</Name>
      <VLANID>$($v.VLANID)</VLANID>
      <IPv4Configuration>Enable</IPv4Configuration>
      <IPv6Configuration>Disable</IPv6Configuration>
      <IPv4Assignment>Static</IPv4Assignment>
      <IPAddress>$(& $x $v.IPAddress)</IPAddress>
      <Netmask>$(& $x $v.Netmask)</Netmask>
    </VLAN>
"@
}

function New-ZoneXml {
    param([string]$Name, [string]$Type)
    $n = ConvertTo-XgsXmlText $Name
@"
    <Zone transactionid="$n">
      <Name>$n</Name>
      <Type>$Type</Type>
      <Description>Angelegt per Invoke-XgsVlanBulk</Description>
    </Zone>
"@
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------

if (-not $DumpExisting) {
    $vlans = Import-VlanCsv -Path $CsvPath
    if ($vlans.Count -eq 0) { Write-XgsLog 'CSV enthaelt keine VLANs.' 'WARN'; return }
    Write-XgsLog ("CSV geprueft: {0} VLAN(s), {1} Zone(n), Interface(s): {2}" -f $vlans.Count,
        @($vlans.Zone | Select-Object -Unique).Count, (@($vlans.Interface | Select-Object -Unique) -join ', ')) 'OK'
    $zonesNeeded = @($vlans | Group-Object Zone | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Type = $_.Group[0].ZoneType } })
}

if ($DryRun) {
    $zoneBody = ($zonesNeeded | ForEach-Object { New-ZoneXml $_.Name $_.Type }) -join "`n"
    Set-Content -Path (Join-Path $OutDir "dryrun-$Stamp-zones.xml") -Encoding UTF8 `
        -Value (New-XgsRequestXml -NoLogin -Body "  <Set operation=`"add`">`n$zoneBody`n  </Set>")
    $n = 0
    for ($i = 0; $i -lt $vlans.Count; $i += $BatchSize) {
        $n++
        $chunk = $vlans[$i..([Math]::Min($i + $BatchSize, $vlans.Count) - 1)]
        $body  = ($chunk | ForEach-Object { New-VlanXml $_ }) -join "`n"
        Set-Content -Path (Join-Path $OutDir ("dryrun-$Stamp-vlans-{0:D2}.xml" -f $n)) -Encoding UTF8 `
            -Value (New-XgsRequestXml -NoLogin -Body "  <Set operation=`"add`">`n$body`n  </Set>")
    }
    $vlans | Format-Table Line, Name, VLANID, Hardware, Zone, ZoneType, IPAddress, Netmask -AutoSize | Out-String -Width 250 | Write-Host
    Write-XgsLog "DryRun: $n VLAN-Request(s) + Zonen-Request unter $OutDir abgelegt. Nichts gesendet." 'OK'
    return
}

if (-not $Firewall) { throw 'Parameter -Firewall fehlt (oder -DryRun verwenden).' }
Connect-XgsFirewall -Firewall $Firewall -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck

try {
    if ($DumpExisting) {
        foreach ($tag in 'VLAN', 'Zone', 'Interface', 'LAG') {
            $f = Join-Path $OutDir "existing-$Stamp-$tag.xml"
            (Get-XgsObject -Tag $tag -Raw).Save($f)
            Write-XgsLog "$tag gespeichert: $f" 'OK'
        }
        return
    }

    # Zonen
    $existingZones = @(Get-XgsObject -Tag Zone | ForEach-Object { $_.SelectSingleNode('Name').InnerText })
    $missingZones  = @($zonesNeeded | Where-Object { $existingZones -notcontains $_.Name })

    if ($missingZones.Count -gt 0) {
        if (-not $CreateMissingZones) {
            Write-XgsLog "Fehlende Zonen: $(($missingZones.Name) -join ', ')" 'ERROR'
            throw 'Zonen fehlen. Anlegen in der GUI oder Skript mit -CreateMissingZones starten.'
        }
        Write-XgsLog "Lege $($missingZones.Count) Zone(n) an: $(($missingZones | ForEach-Object { "$($_.Name) ($($_.Type))" }) -join ', ')"
        $items = @($missingZones | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Xml = (New-ZoneXml $_.Name $_.Type) } })
        $res   = Set-XgsObject -Tag Zone -Items $items -BatchSize $BatchSize
        foreach ($r in $res) {
            Write-XgsLog "Zone $($r.Key): [$($r.Code)] $($r.Message)" $(if ($r.Ok) { 'OK' } else { 'ERROR' })
        }
        $failed = @($res | Where-Object { -not $_.Ok }).Count
        if ($failed -gt 0) { throw "$failed Zone(n) konnten nicht angelegt werden. Abbruch vor dem Anlegen der VLANs." }
    }
    else {
        Write-XgsLog "Alle benoetigten Zonen vorhanden: $(($zonesNeeded.Name) -join ', ')" 'OK'
    }

    # Vorhandene VLANs
    $existing     = Get-XgsObject -Tag VLAN
    $existingHw   = @($existing | ForEach-Object { $n = $_.SelectSingleNode('Hardware'); if ($n) { $n.InnerText } })
    $existingName = @($existing | ForEach-Object { $n = $_.SelectSingleNode('Name'); if ($n) { $n.InnerText } })

    $results = New-Object System.Collections.Generic.List[object]
    $todo    = New-Object System.Collections.Generic.List[object]
    foreach ($v in $vlans) {
        $skip = if ($existingHw -contains $v.Hardware) { 'existiert bereits' }
                elseif ($existingName -contains $v.Name) { 'Name bereits vergeben' }
        if ($skip) {
            $results.Add([pscustomobject]@{ Hardware = $v.Hardware; Name = $v.Name; Zone = $v.Zone; Result = 'SKIP'; Message = $skip })
            Write-XgsLog "$($v.Hardware) ($($v.Name)): $skip, uebersprungen" 'WARN'
        }
        else { $todo.Add($v) }
    }

    # VLANs anlegen
    if ($todo.Count -gt 0) {
        $items = @($todo | ForEach-Object { [pscustomobject]@{ Key = $_.Hardware; Xml = (New-VlanXml $_) } })
        $res   = Set-XgsObject -Tag VLAN -Items $items -BatchSize $BatchSize
        foreach ($r in $res) {
            $v = $todo | Where-Object Hardware -eq $r.Key | Select-Object -First 1
            $results.Add([pscustomobject]@{ Hardware = $v.Hardware; Name = $v.Name; Zone = $v.Zone; Result = $(if ($r.Ok) { 'OK' } else { 'FEHLER' }); Message = "[$($r.Code)] $($r.Message)" })
            Write-XgsLog "$($v.Hardware) ($($v.Name), $($v.Zone)): [$($r.Code)] $($r.Message)" $(if ($r.Ok) { 'OK' } else { 'ERROR' })
        }
    }

    # Zusammenfassung
    $csvOut = Join-Path $LogDir "result-$Stamp.csv"
    $results | Export-Csv -Path $csvOut -Delimiter ';' -NoTypeInformation -Encoding UTF8
    $results | Format-Table Hardware, Name, Zone, Result, Message -AutoSize | Out-String -Width 250 | Write-Host

    $cntOk   = @($results | Where-Object Result -eq 'OK').Count
    $cntSkip = @($results | Where-Object Result -eq 'SKIP').Count
    $cntErr  = @($results | Where-Object Result -eq 'FEHLER').Count
    Write-XgsLog "Fertig: $cntOk angelegt, $cntSkip uebersprungen, $cntErr Fehler. Ergebnis: $csvOut" $(if ($cntErr) { 'WARN' } else { 'OK' })
    if ($cntErr -gt 0) {
        Write-XgsLog 'Details zu Fehlern auf der Firewall: /log/apiparser.log (Advanced Shell)' 'WARN'
        $script:ExitCode = 1
    }
}
finally {
    Disconnect-XgsFirewall
}
exit $script:ExitCode
