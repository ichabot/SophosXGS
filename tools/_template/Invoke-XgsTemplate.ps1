<#
.SYNOPSIS
    Vorlage fuer neue Tools. Ordner kopieren, umbenennen, loslegen.

.DESCRIPTION
    Zeigt den Grundaufbau: Modul laden, Log starten, verbinden, Objekte lesen,
    am Ende die Sitzung schliessen. Beispiel liest alle Zonen und gibt sie aus.

.EXAMPLE
    .\Invoke-XgsTemplate.ps1 -Firewall 192.168.1.1 -SkipCertificateCheck
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Firewall,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\modules\XgsApi\XgsApi.psm1') -Force -DisableNameChecking
Start-XgsLog -Path (Join-Path $PSScriptRoot ("logs\run-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))

Connect-XgsFirewall -Firewall $Firewall -Credential $Credential -SkipCertificateCheck:$SkipCertificateCheck
try {
    Get-XgsObject -Tag Zone | ForEach-Object {
        [pscustomobject]@{
            Name = $_.SelectSingleNode('Name').InnerText
            Type = $_.SelectSingleNode('Type').InnerText
        }
    } | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
}
finally {
    Disconnect-XgsFirewall
}
