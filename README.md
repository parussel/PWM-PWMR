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
[153er-netz.de](https://153er-netz.de/seiten/entwicklung/fhem.html) gepflegt.

## Funktionsumfang

Das Updatepaket enthält seit dem 21.11.2026 drei Dateien. `93_PWMR.pm` und
`94_PWM.pm` bilden weiterhin die vollständig eigenständig nutzbare, bisherige
PWM/PWMR-Regelung. `98_FBHKeepAlive.pm` ist eine optionale Erweiterung. Alle
drei Dateien werden gemeinsam ausgeliefert, die dritte Datei wird aber erst
durch eine ausdrückliche Zuordnung an einem PWMR-Raum wirksam.

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
- **Dynamische FBH-Erhaltungspulse:** Das optionale Modul
  `98_FBHKeepAlive.pm` lernt für jeden PWMR-Raum einen begrenzten Pulsabstand
  aus echten, nach der Filterverzögerung gemessenen Rücklauftemperaturen.
  Die Pulsdauer bleibt fest. Ohne Provider, im Shadow-Modus, bei fehlendem
  Lernzyklus oder bei ungültigen/veralteten Sensordaten bleibt automatisch
  der vorhandene statische `maxOffTime`-Wert wirksam.

## Betrieb nur mit PWM und PWMR

Bestehende Definitionen bleiben abwärtskompatibel. Ohne die PWMR-Attribute
`floorReturn` und `floorKeepAliveProvider` arbeiten `93_PWMR.pm` und
`94_PWM.pm` genauso wie zuvor. Insbesondere bleibt `maxOffTime` die statische
Erhaltungspulsregelung. Am PWM-Gerät ist für den Betrieb ohne oder mit
FBHKeepAlive kein zusätzliches Attribut notwendig. Die interne
Koordinationsprüfung in PWM gibt Räume ohne Providerzuordnung unmittelbar frei.

## Dynamische Erhaltungspulse einrichten

### Voraussetzung: TempReadingFilter

FBHKeepAlive benötigt einen hydraulisch aussagekräftigen Rücklaufwert. Dafür
ist das eigenständige Modul
[TempReadingFilter](https://github.com/parussel/TempReadingFilter) erforderlich.
Es beginnt nach dem Öffnen des zugehörigen Ventils eine Verzögerungsphase und
gibt erst danach das am Rücklauf eingetroffene Wasser als gültigen Messwert
weiter. Ein ungefilterter Sensorwert aus einem geschlossenen Heizkreis ist
keine geeignete Grundlage für FBHKeepAlive.

Beispiel:

```text
define EG_Bad_RL_TF TempReadingFilter EG_Bad_RL realtemperature EG_Bad_Ventil on
attr EG_Bad_RL_TF delay 600
```

Die konkrete Definition richtet sich nach Sensor, Reading und Ventilaktor der
Installation. Die feste Erhaltungspulsdauer muss größer als die
Filterverzögerung sein. Bei 600 Sekunden Verzögerung werden 20 Minuten
Pulsdauer empfohlen.

Ein Provider wird pro PWM-Gruppe definiert. Außensensor und Reading sind
frei wählbar; `none` ist zulässig:

```text
define FBHKeepAlive_EG FBHKeepAlive PWM_EG Temperatur_Aussen:realtemperature
attr FBHKeepAlive_EG mode shadow
attr FBHKeepAlive_EG minPulseDuration 20
attr FBHKeepAlive_EG coordinationGroup FBH_Gemeinsam
attr FBHKeepAlive_EG stateFile /opt/fhem/log/FBHKeepAlive_EG.json
```

Jeder gewünschte PWMR-Raum erhält den gefilterten Rücklauf und seinen
Provider:

```text
attr EG_Bad_PWM floorReturn EG_Bad_RL_TF:realtemperature
attr EG_Bad_PWM floorKeepAliveProvider FBHKeepAlive_EG
```

### Betriebsarten und Rückfall

- `mode active`: Eine frische und gültige Lernentscheidung darf den statischen
  Abstand für die aktuelle Berechnung ersetzen.
- `mode shadow`: Das Modul beobachtet und lernt, PWMR verwendet jedoch immer
  das unveränderte statische `maxOffTime`.
- `mode off`: Dynamische Werte werden nicht angewendet.
- `disable 1`: Auswertung und Lernen werden vollständig angehalten.

Fehlt ein Provider, eine Zuordnung, ein gültiger Lernzyklus oder ein frischer
Sensorwert, meldet PWMR `keepAliveMode = static-fallback`. `maxOffTime` wird
niemals überschrieben oder gelöscht. Der erste Lernwert beginnt beim
vorhandenen statischen Raumwert; `initialInterval` ist nur der Ersatz, falls
kein nutzbarer Raumwert vorhanden ist.

`shadow` berechnet und zeigt nur Diagnosen. Nach der Prüfung aktiviert
`attr FBHKeepAlive_EG mode active` die dynamischen Abstände. Erfasst werden
nur Messungen, bei denen der `TempReadingFilter` den Zustand `active` meldet;
dessen reine Keepalive-Aktualisierungen im Ruhezustand werden nicht gelernt.
Der gefilterte Messwert muss außerdem zeitlich nach dem Beginn der aktiven
Filterphase liegen; ein noch zwischengespeicherter Altwert wird nicht als
neue Bodenmessung verwendet. Die Pulsdauer muss größer als die konfigurierte
Filterverzögerung sein, andernfalls bleibt der statische Rückfall aktiv.
Pro zusammenhängender Ventilöffnung wird genau eine Lernentscheidung gebildet,
auch wenn währenddessen mehrere Sensorwerte eintreffen.
Eine gültige Außentemperaturänderung von mindestens 0,5 K wirkt nur dann als
begrenzter Tie-Breaker, wenn Raum- und Rücklaufbewertung ansonsten stabil sind;
sie kann deshalb keine stärkere raumbezogene Entscheidung übersteuern.
Der erste Lernwert beginnt beim bereits vorhandenen statischen Raumwert und
verursacht deshalb keinen sprunghaften Wechsel. `set ... freeze`, `unfreeze`,
`reset` und `evaluate` unterstützen Diagnose und Service. Zwei Provider mit
derselben `coordinationGroup` lassen höchstens einen fälligen dynamischen
Erhaltungspuls gleichzeitig zu. Die Freigabe erfolgt erst bei der endgültigen
PWM-Auswahl; eine kurze Reservierung überbrückt die Schaltbestätigung und der
tatsächlich gemeldete Aktorzustand verhindert Überschneidungen auch über die
Reservierungszeit hinaus.

### Lernentscheidung

Pro zusammenhängender Ventilöffnung wird höchstens ein gültiger Zyklus
verarbeitet. Die Priorität lautet:

1. Liegt die gemessene Raumtemperatur mehr als 0,2 K unter dem Sollwert, wird
   der künftige Abstand um `intervalStep` verkürzt. Liegt sie mehr als 0,2 K
   darüber, wird er verlängert.
2. Liegt der Raum im Sollbereich, entscheidet die Änderung zum letzten
   gültigen Rücklauf. Unterhalb `targetOffsetLow` wird verkürzt, oberhalb
   `targetOffsetHigh` verlängert; innerhalb des Bandes bleibt der Abstand.
3. Nur wenn Raum und Rücklauf stabil sind, dient die Außentemperatur als
   nachrangiger Tie-Breaker. Eine Änderung ab 0,5 K verändert den Abstand um
   einen Schritt in die entsprechende Richtung.

Standardmäßig beträgt ein Schritt 30 Minuten. Der Abstand bleibt innerhalb
`minInterval` und `maxInterval`, standardmäßig 120 bis 480 Minuten. Die
Pulsdauer wird nicht gelernt. Diagnose-Readings nennen unter anderem
Intervall, Rücklauf, Trend, Zielband, Begründung, Vertrauen und Rückfall.

### Neustartsichere Lernwerte und Langzeitprotokoll

`stateFile` legt für jede Providerinstanz eine eigene JSON-Zustandsdatei fest.
Nach jedem abgeschlossenen Lernzyklus wird sie über eine temporäre Datei
atomar ersetzt. Gespeichert werden je Raum Intervall, letzter Rücklauf,
Rücklauftrend, letzter Außenwert, Anzahl der Lernzyklen und Freeze-Zustand.
Nach einem Neustart werden diese Werte geladen und vor ihrer Verwendung gegen
die aktuelle Konfiguration und aktuelle Sensorwerte geprüft. Eine fehlende,
beschädigte oder unpassende Datei führt sicher zu `static-fallback`.

Für Langzeitanalysen erzeugt jeder Lernzyklus ein vollständiges Reading
`learningEvent_<Raum>`. Es enthält alten und neuen Abstand, Raum-Ist und
-Soll, Rücklauf, Rücklaufdifferenz, Außentemperatur, Grund und Vertrauen.
Beispiel für ein tägliches FileLog mit 180 Tagen Aufbewahrung:

```text
define FileLog_FBHKeepAlive_EG FileLog /opt/fhem/log/%Y-%m-%d-FBHKeepAlive_EG.log FBHKeepAlive_EG:(learningEvent_.*|persistenceStatus|lastService):.*
attr FileLog_FBHKeepAlive_EG nrarchive 180
```

`reset <Raum>` beziehungsweise `reset all` aktualisiert auch die persistente
Datei. `freeze` und `unfreeze` werden ebenfalls neustartsicher gespeichert.
Ein zukünftiger statischer Vorschlagswert soll erst aus ausreichend vielen
Langzeitdaten abgeleitet und nur angezeigt, niemals automatisch in
`maxOffTime` geschrieben werden.

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
FHEM/98_FBHKeepAlive.pm
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

`98_FBHKeepAlive.pm` besitzt kein offizielles gleichnamiges FHEM-Modul. Nach
dem Zurückwechseln Definitionen/Attribute entfernen und die Datei erst danach
manuell aus `FHEM/` löschen.

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
