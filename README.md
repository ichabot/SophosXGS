# SophosXGS

Sammlung von PowerShell-Tools zur Automatisierung von Sophos Firewalls (XGS / SFOS) über die XML-API.

Alle Tools laufen unter Windows PowerShell 5.1 und PowerShell 7 und brauchen keine zusätzlichen Module.

## Tools

| Tool | Zweck |
|------|-------|
| [vlan-bulk](tools/vlan-bulk/) | Viele VLAN-Interfaces aus einer CSV anlegen, fehlende Zonen optional mit anlegen |

## Aufbau

```
SophosXGS/
├── modules/
│   └── XgsApi/            Gemeinsame Funktionen (Login, Requests, Logging, Validierung)
│       └── XgsApi.psm1
└── tools/
    ├── _template/         Vorlage für neue Tools
    └── vlan-bulk/         Je Tool ein Ordner mit Skript, README und Beispieldaten
```

Jedes Tool liegt in einem eigenen Ordner unter `tools/` und bindet das gemeinsame Modul über einen relativen Pfad ein. Laufzeitdaten (`output/`, `logs/`) entstehen im jeweiligen Tool-Ordner und werden nicht eingecheckt.

## Voraussetzungen auf der Firewall

1. **Backup & Firmware → API**: API-Konfiguration aktivieren und die IP des ausführenden Clients unter *Allowed IP address* eintragen.
2. Admin-Benutzer für die API (am besten ein eigener Benutzer mit Admin-Profil).
3. Erreichbar über den Admin-Port, Standard **4444**. Abweichender Port: `-Firewall 1.2.3.4:PORT`.
4. Vor Änderungen ein Konfig-Backup ziehen.

## Schnellstart

```powershell
git clone https://github.com/ichabot/SophosXGS.git
cd SophosXGS

# Falls Skripte blockiert sind (nur für diese Sitzung):
Set-ExecutionPolicy -Scope Process Bypass
Get-ChildItem -Recurse -Include *.ps1, *.psm1 | Unblock-File

cd tools\vlan-bulk
# weiter laut README des Tools
```

## Gemeinsames Modul `XgsApi`

| Funktion | Zweck |
|----------|-------|
| `Connect-XgsFirewall` | Sitzung anlegen, Login testen (`-SkipCertificateCheck` für selbstsignierte Zertifikate) |
| `Disconnect-XgsFirewall` | Zugangsdaten aus dem Speicher entfernen |
| `Invoke-XgsRequest` | Beliebigen Request-Body senden, Antwort als `[xml]` |
| `Get-XgsObject` | Alle Objekte eines Typs lesen, z. B. `VLAN`, `Zone`, `Interface`, `LAG`, `IPHost` |
| `Set-XgsObject` | Objekte per `add`/`update` in Batches senden, Ergebnis je Objekt |
| `New-XgsRequestXml` | Request-XML erzeugen, mit `-NoLogin` ohne Zugangsdaten (DryRun) |
| `Import-XgsCsv` | CSV mit `;` oder `,` einlesen, Kommentar- und Leerzeilen ignorieren |
| `Start-XgsLog` / `Write-XgsLog` | Logdatei und farbige Konsolenausgabe |
| `Test-XgsIPv4` / `ConvertTo-XgsNetmask` | Validierung |

## Neues Tool hinzufügen

1. `tools/_template` nach `tools/<tool-name>` kopieren (Kleinbuchstaben, Bindestriche).
2. Skript nach `Invoke-Xgs<Name>.ps1` umbenennen und die Logik einbauen.
3. README im Tool-Ordner schreiben, Beispieldaten als `*.example.csv` ablegen.
4. Tool oben in der Tabelle eintragen.

Regeln, damit sich die Tools nicht in die Quere kommen:

- Pro Tool ein eigener Ordner, keine Dateien direkt unter `tools/`.
- API-Zugriff nur über das Modul. Was mehrere Tools brauchen, kommt in `XgsApi.psm1`.
- Änderungen am Modul abwärtskompatibel halten (neue Parameter optional), damit bestehende Tools weiterlaufen.
- Tools mit Schreibzugriff bekommen einen `-DryRun`.
- Echte Kundendaten (`*.csv` ohne `.example`) bleiben lokal, die `.gitignore` sorgt dafür.

## Fehlersuche allgemein

- **Login fehlgeschlagen**: API aktiviert? Client-IP freigegeben? Benutzer/Passwort korrekt?
- **Statuscode ≠ 200**: Details auf der Firewall in der Advanced Shell unter `/log/apiparser.log`.
- **Feldnamen unklar**: Objekt in der GUI anlegen und per `Get-XgsObject -Tag <Typ> -Raw` auslesen. So sieht man das Schema der eigenen Firmware.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
