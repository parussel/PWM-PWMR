# PWM / PWMR – erweiterte FHEM-Version

Eine kompatible, eigenständig installierbare Erweiterung der ursprünglichen
FHEM-Module `94_PWM.pm` und `93_PWMR.pm` für pulsweitenmodulierte Heizungs-
und Raumregelung.

> **Status:** Erste öffentliche 153er-netz.de-Version. Dies ist kein
> offizieller Bestandteil von FHEM. Vor jeder Installation eine Sicherung
> erstellen und die Regelung nach der Umstellung beobachten. Einsatz in
> eigener Verantwortung.

Die ursprünglichen Autoren- und Herkunftshinweise bleiben in beiden
Moduldateien erhalten. Die Erweiterungen von 2026 werden von Frank Parussel /
[153er-netz.de](https://153er-netz.de/seiten/entwicklung.html) gepflegt.

## Funktionsumfang

Die Dateien `93_PWMR.pm` und `94_PWM.pm` gehören zusammen und bleiben bei
jedem Update gemeinsam im Paket.

- **Feinere Solltemperaturauswahl:** `tempStep` bietet wahlweise 0,5-K- oder
  0,1-K-Schritte in der Solltemperaturauswahl.
- **Fensterkontakte:** Das Attribut `window` erlaubt eine einfache Angabe von
  Fensterkontakten und Readings. Bei offenem Fenster wird der Heizpuls sicher
  auf null gesetzt; das Reading `window` zeigt `open` oder `closed`.
- **Ventil-Service-Override:** `valveOverride` schaltet einen zugeordneten
  Aktor unmittelbar, solange der konfigurierte Servicezustand aktiv ist. Das
  Reading `valveOverride` zeigt `on` oder `off`.
- **D-Pufferschutz:** Die PID-D-Berechnung behandelt eine leere Historie
  robust und erzeugt daraus keinen künstlichen Differenzialanteil.
- **Korrigierter `readingsProxy`-Abgleich:** Nach einem Proxy-Schaltbefehl
  gilt ein Wechsel nur als bestätigt, wenn das Reading `state` den erwarteten
  Zustand meldet. Eine leere Befehlsrückgabe allein setzt weder `actorState`
  noch `lastswitch` als erfolgreich geschaltet.

Die Prüfung betrifft den **gemeldeten Softwarezustand**. Sie kann weder die
mechanische Ventilstellung noch Durchfluss oder Raumtemperatur garantieren.

## Installation und Updates

Führe die Befehle einzeln im FHEM-Kommandoeingabefeld aus und prüfe jeweils
die Rückmeldung. Bestehende Definitionen, Attribute und Readings werden durch
die Steuerdatei nicht verändert.

### Offizielle Dateien gezielt ausschließen

Prüfe zuerst den bisherigen Wert:

```text
{ 'WERT: '.AttrVal('global','exclude_from_update','NICHT_GESETZT') }
```

Wenn die jeweiligen Regeln noch nicht vorhanden sind, füge sie **zusätzlich**
hinzu. Sie schließen ausschließlich die beiden gleichnamigen Dateien aus der
offiziellen Quelle aus. Andere eigene Ausschlussregeln bleiben erhalten.

```text
attr -a global exclude_from_update fhem\.de.*:FHEM/93_PWMR\.pm
```

```text
attr -a global exclude_from_update fhem\.de.*:FHEM/94_PWM\.pm
```

```text
save
```

### Erweiterte Version anmelden

```text
update add https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

```text
update check https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

Die Vorschau muss genau diese Dateien nennen:

```text
FHEM/93_PWMR.pm
FHEM/94_PWM.pm
```

Danach installieren und FHEM neu starten:

```text
update all https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

```text
shutdown restart
```

## Rückkehr zum offiziellen FHEM-Stand

Entferne zunächst die Community-Quelle:

```text
update delete https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

Entferne danach ausschließlich die beiden vorher ergänzten Regeln:

```text
attr -r global exclude_from_update fhem\.de.*:FHEM/93_PWMR\.pm
```

```text
attr -r global exclude_from_update fhem\.de.*:FHEM/94_PWM\.pm
```

```text
save
```

Stelle abschließend beide offiziellen Dateien wieder her und starte FHEM neu:

```text
update 93_PWMR.pm https://fhem.de/fhemupdate/controls_fhem.txt
```

```text
update 94_PWM.pm https://fhem.de/fhemupdate/controls_fhem.txt
```

```text
shutdown restart
```

## Prüfsummen und Prüfung

`SHA256SUMS.txt` enthält die Prüfsummen der tatsächlich verteilten
Moduldateien. Die veröffentlichte Version wurde vor der Bereitstellung mit
automatisierten Regressionstests und in einer isolierten FHEM-nahen Umgebung
geprüft. Das ersetzt keine Prüfung der eigenen Heizungsanlage, insbesondere
nicht von Ventilstellung, Durchfluss oder externen Aktor-Rückmeldungen.

## Herkunft und Lizenz

Die Module bauen auf den ursprünglichen FHEM-Modulen von Andreas Goebel und
späteren FHEM-Beiträgen auf. Die vollständige Zuordnung steht in
[NOTICE.md](NOTICE.md). Lizenz: GNU General Public License, Version 2 oder
nach eigener Wahl eine spätere Version (`GPL-2.0-or-later`); siehe
[LICENSE](LICENSE).

Eine kurze englische Zusammenfassung steht in [README.en.md](README.en.md).
