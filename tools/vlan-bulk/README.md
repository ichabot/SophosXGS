# vlan-bulk

Legt viele VLAN-Interfaces aus einer CSV auf einer Sophos Firewall an. Fehlende Zonen können mit angelegt werden.

Voraussetzungen auf der Firewall: siehe [Haupt-README](../../README.md#voraussetzungen-auf-der-firewall).

## CSV ausfüllen

`vlans.example.csv` nach `vlans.csv` kopieren und befüllen (Excel speichert mit `;`, Komma geht auch).

| Spalte      | Pflicht | Beschreibung                                                                    |
|-------------|---------|---------------------------------------------------------------------------------|
| `Name`      | ja      | Anzeigename des VLAN-Interfaces auf der Firewall (max. 50 Zeichen)              |
| `VLANID`    | ja      | 1–4094                                                                          |
| `Interface` | ja      | Physischer Port oder LAG, z. B. `PortA1`, `PortB`, `LAG_CORE`                   |
| `Zone`      | ja      | Zielzone, z. B. `LAN`, `DMZ` oder eigene Zone                                   |
| `ZoneType`  | nein    | `LAN` (Standard) oder `DMZ`. Wird nur benutzt, wenn die Zone neu angelegt wird  |
| `IPAddress` | ja      | IP der Firewall im VLAN (Gateway-Adresse für die Clients)                       |
| `Netmask`   | ja      | `255.255.255.0`, `24` oder `/24`                                                |

Zeilen, die mit `#` beginnen, und leere Zeilen werden ignoriert.

## Ausführen

```powershell
cd tools\vlan-bulk
Copy-Item vlans.example.csv vlans.csv   # dann befüllen

# 1. Trockenlauf: CSV prüfen, Request-XMLs nach .\output schreiben, nichts senden
.\Invoke-XgsVlanBulk.ps1 -DryRun

# 2. Anlegen (Zugangsdaten werden abgefragt)
.\Invoke-XgsVlanBulk.ps1 -Firewall 192.168.1.1 -SkipCertificateCheck -CreateMissingZones
```

## Parameter

| Parameter               | Zweck                                                                                       |
|-------------------------|---------------------------------------------------------------------------------------------|
| `-Firewall`             | IP/Hostname, optional mit `:Port`                                                           |
| `-CsvPath`              | Andere CSV als `.\vlans.csv`                                                                |
| `-Credential`           | PSCredential übergeben statt Abfrage                                                        |
| `-DryRun`               | Nur prüfen und XML erzeugen                                                                 |
| `-CreateMissingZones`   | Fehlende Zonen anlegen. Ohne Schalter bricht das Skript ab, wenn eine Zone fehlt            |
| `-BatchSize`            | VLANs pro Request (Standard 10)                                                             |
| `-SkipCertificateCheck` | Selbstsigniertes Admin-Zertifikat akzeptieren                                               |
| `-DumpExisting`         | Vorhandene VLANs, Zonen, Interfaces und LAGs als XML nach `.\output` speichern und beenden  |

## Verhalten

- VLANs, die es auf dem Interface schon gibt (gleiche `Interface.VLANID`), und bereits vergebene Namen werden übersprungen. Ein erneuter Lauf ist daher unkritisch.
- Neue Zonen werden nur mit Name, Typ und Beschreibung angelegt. **Gerätezugriff (Ping, DNS, HTTPS, SSH …) danach in der GUI pro Zone setzen.**
- DHCP und Firewall-Regeln legt das Tool nicht an.
- Ergebnis je VLAN: Konsole, `.\logs\run-*.log` und `.\logs\result-*.csv`. Exit-Code 1, wenn mindestens ein VLAN fehlgeschlagen ist.

## Fehlersuche

- **Status 500 bei einzelnen VLANs**: `/log/apiparser.log` auf der Firewall prüfen.
- **Schema passt nicht zur Firmware**: Ein VLAN in der GUI anlegen, `-DumpExisting` ausführen und `output\existing-*-VLAN.xml` mit `output\dryrun-*-vlans-01.xml` vergleichen. Fehlende Pflichtfelder in `New-VlanXml` ergänzen.
