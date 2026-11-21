# PWM, PWMR und PWMK – erweiterte FHEM-Module

Diese Erweiterung ist aus einer realen Fußbodenheizungsanlage entstanden. Ein
Raum kann seine Solltemperatur bereits erreicht haben, während der Estrich bis
zur nächsten regulären Heizanforderung deutlich auskühlt. Beim späteren Öffnen
nimmt der Heizkreis schlagartig viel Energie auf; dadurch können Vorlauf,
Mischer und hydraulisch gekoppelte Kreise einbrechen.

PWMK hält den Boden nicht mit einem pauschalen Dauerwert warm. Das Modul lernt
raumindividuelle Abstände für kurze Erhaltungspulse. Als Grundlage dient ein
Rücklaufwert, den der TempReadingFilter erst nach ausreichender Durchströmung
als hydraulisch belastbar freigibt.

Die ausführliche Beschreibung von Hydraulik, DS18B20-Anlegefühlern,
OneWire/OW2S0SMSGUARD, I²C/MCP-Ventilansteuerung, TempReadingFilter, PWM, PWMR,
PWMK, PID20 und einer möglichen Shelly/MQTT-Nachrüstung steht in der
**[zentralen Dokumentation der Heizungsregelkette](HEIZUNGSREGELKETTE.md)**.

Diese eigenständig installierbare FHEM-Erweiterung besteht aus drei
aufeinander abgestimmten Modulen:

| Modul | Aufgabe | Erforderlich? |
|---|---|---|
| `PWM` | zentrale Pulsweitenmodulation und zeitliche Verteilung | ja |
| `PWMR` | Raumregelung, Sollwert, Sensor, Ventil und statischer Erhaltungspuls | ja |
| `PWMK` – **PWM KeepAlive** | dynamische Erhaltungspulse anhand belastbarer Rücklaufwerte | optional |

```text
PWM → PWMR → Raumventil → TempReadingFilter → PWMK → dynamischer Pulsabstand
```

`PWM` und `PWMR` bleiben ohne `PWMK` vollständig eigenständig und
abwärtskompatibel. PWMK wird nur wirksam, wenn ein PWMR-Raum ausdrücklich
über `floorKeepAliveProvider` zugeordnet wurde.

> **Entwicklungsstand 21.11.2026:** PWMK ist eine vollständige Neuentwicklung.
> Automatisierte Prüfungen und die erste reale Inbetriebnahme sind erfolgt.
> Langzeitbeobachtung und Feinschliff folgen anhand der protokollierten
> Heizsaison. Vor Installation sichern und die eigene Anlage beobachten.

Wer die kurzzeitig am 21.11.2026 veröffentlichte Rohfassung
`98_FBHKeepAlive.pm` installiert hat, verwendet bitte ausschließlich die
[Kurzanleitung zur Umstellung auf PWMK](MIGRATION-2026-11-21-FBHKEEPALIVE-ZU-PWMK.md).

## Zusammenspiel der Module

### PWM – zeitliche Gesamtsteuerung

PWM sammelt die Anforderungen der PWMR-Räume und verteilt deren Einschaltzeiten.
Für PWMK ist am PWM-Gerät kein zusätzliches Attribut nötig.

### PWMR – Regelung eines Raums

PWMR berechnet den Wärmebedarf und schaltet das Raumventil. Ohne PWMK begrenzt
`maxOffTime` weiterhin statisch die Ausschaltzeit. Die erweiterte Version
unterstützt feinere Sollwerte, Fenster-Hartabschaltung, Ventil-Service-Override
und eine robuste D-Anteil-Berechnung.

### PWMK – PWM KeepAlive

PWMK lernt je PWMR-Raum ausschließlich den Abstand zwischen Erhaltungspulsen;
die Pulsdauer bleibt fest. Grundlage sind nur Rücklaufwerte, die der separate
[TempReadingFilter](https://github.com/parussel/TempReadingFilter) nach der
hydraulischen Transportzeit als gültig meldet.

Fehlen Provider, Lernzyklus oder frische Sensordaten, verwendet PWMR automatisch
den unveränderten statischen `maxOffTime`. PWMK überschreibt dieses Attribut nie.

## Funktionsumfang

- Solltemperaturen wahlweise in 0,5-K- oder 0,1-K-Schritten (`tempStep`)
- Fensterkontakte mit sicherer Abschaltung (`window`)
- Serviceeingang für Ventile (`valveOverride`)
- robuster D-Anteil und bestätigter `readingsProxy`-Abgleich
- dynamischer raumbezogener Erhaltungspulsabstand mit sicherem Rückfall
- neustartsichere Lernwerte in atomar ersetzten JSON-Dateien
- vollständige Lernereignisse für langfristige FileLogs
- Koordination mehrerer PWMK-Instanzen gegen kollidierende Pulse

## Installation und Update

Alle Befehle einzeln im FHEM-Kommandoeingabefeld ausführen und die jeweilige
Rückmeldung prüfen.

### 1. Vorhandene Ausschlüsse prüfen und ergänzen

```text
{ 'WERT: '.AttrVal('global','exclude_from_update','NICHT_GESETZT') }
attr -a global exclude_from_update fhem\.de.*:FHEM/93_PWMR\.pm
attr -a global exclude_from_update fhem\.de.*:FHEM/94_PWM\.pm
save
```

### 2. Erweiterte Quelle anmelden

```text
update add https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

### 3. Vorschau prüfen

```text
update check https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

Die Vorschau muss genau diese Moduldateien nennen:

```text
FHEM/93_PWMR.pm
FHEM/94_PWM.pm
FHEM/95_PWMK.pm
```

### 4. Installieren und neu starten

```text
update all https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
shutdown restart
```

## Betrieb nur mit PWM und PWMR

Ohne die PWMR-Attribute `floorReturn` und `floorKeepAliveProvider` bleibt
`maxOffTime` die alleinige Erhaltungspulsregelung. Das PWM-Modul erkennt
automatisch, dass kein PWMK zugeordnet ist.

## PWMK einrichten

### 1. Gefilterten Rücklauf bereitstellen

```text
define EG_Bad_RL_TF TempReadingFilter EG_Bad_RL realtemperature EG_Bad_Ventil on
attr EG_Bad_RL_TF delay 600
```

Die feste Erhaltungspulsdauer muss länger als die Filterverzögerung sein; bei
600 Sekunden Filterzeit sind 20 Minuten ein sinnvoller Ausgangswert.

### 2. PWMK-Provider definieren

```text
define PWMK_EG PWMK PWM_EG Temperatur_Aussen:realtemperature
attr PWMK_EG mode shadow
attr PWMK_EG minPulseDuration 20
attr PWMK_EG coordinationGroup FBH_Gemeinsam
attr PWMK_EG event-on-change-reading learningEvent_.*,persistenceStatus,lastService,state
```

Außensensor und Reading sind frei wählbar. Ohne Außeneinfluss wird `none`
angegeben. Ohne `stateFile` speichert PWMK relativ zum Verzeichnis des unter
`global statefile` eingestellten FHEM-Zustands.

### 3. PWMR-Raum zuordnen

```text
attr EG_Bad_PWM floorReturn EG_Bad_RL_TF:realtemperature
attr EG_Bad_PWM floorKeepAliveProvider PWMK_EG
```

### 4. Beobachten und aktivieren

`shadow` lernt ohne Eingriff. Nach der Prüfung aktiviert folgender Befehl die
dynamischen Abstände:

```text
attr PWMK_EG mode active
```

## Betriebsarten und Rückfall

| Einstellung | Wirkung |
|---|---|
| `mode shadow` | lernen und anzeigen; PWMR nutzt statisches `maxOffTime` |
| `mode active` | frische gültige Lernwerte dürfen den Abstand ersetzen |
| `mode off` | keine dynamische Anwendung |
| `disable 1` | Auswertung und Lernen vollständig anhalten |

Bei ungültigen Voraussetzungen erscheint `keepAliveMode = static-fallback`.
Der vorhandene `maxOffTime`-Wert bleibt unverändert.

## Lernverfahren

Pro zusammenhängender Ventilöffnung wird höchstens ein Zyklus gelernt:

1. Mehr als 0,2 K unter Soll verkürzt den Abstand um `intervalStep`; mehr als
   0,2 K über Soll verlängert ihn.
2. Im Sollband entscheidet die Rücklaufänderung anhand `targetOffsetLow` und
   `targetOffsetHigh`.
3. Nur bei stabiler Raum- und Rücklaufbewertung wirkt eine Änderung der
   Außentemperatur ab 0,5 K als begrenzter Tie-Breaker.

Standardmäßig beträgt ein Schritt 30 Minuten. `minInterval` und `maxInterval`
begrenzen den Abstand auf 120 bis 480 Minuten. Der erste Wert beginnt beim
vorhandenen statischen Raumwert und verursacht keinen sprunghaften Wechsel.

## Diagnose, Service und Langzeitprotokoll

```text
set PWMK_EG evaluate
set PWMK_EG freeze all
set PWMK_EG unfreeze all
set PWMK_EG reset all
```

Statt `all` kann ein PWMR-Gerätename angegeben werden. Readings zeigen unter
anderem Intervall, Pulsdauer, Rücklauf, Trend, Zielband, nächsten Puls,
Vertrauen, Begründung, Rückfall und Warteschlange. `learningEvent_<Raum>`
enthält den vollständigen Datensatz eines angenommenen Lernzyklus.

```text
define FileLog_PWMK_EG FileLog ./log/%Y-%m-%d-PWMK_EG.log PWMK_EG:(learningEvent_.*|persistenceStatus|lastService):.*
attr FileLog_PWMK_EG nrarchive 180
```

## Quelle wieder entfernen

```text
update delete https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

Dies entfernt nur die Community-Quelle; installierte Dateien bleiben bestehen.

## Rückkehr zum offiziellen FHEM-Stand

Zunächst PWMK aus PWMR-Zuordnungen und Definitionen entfernen, anschließend
`FHEM/95_PWMK.pm` manuell löschen. Danach nur die zuvor ergänzten Regeln
entfernen und die offiziellen Dateien wiederherstellen:

```text
attr -r global exclude_from_update fhem\.de.*:FHEM/93_PWMR\.pm
attr -r global exclude_from_update fhem\.de.*:FHEM/94_PWM\.pm
save
update 93_PWMR.pm https://fhem.de/fhemupdate/controls_fhem.txt
update 94_PWM.pm https://fhem.de/fhemupdate/controls_fhem.txt
shutdown restart
```

## Prüfsummen, Herkunft und Lizenz

`SHA256SUMS.txt` enthält die Prüfsummen der verteilten Module. Die ursprünglichen
Autorenhinweise bleiben erhalten; Details stehen in [NOTICE.md](NOTICE.md).
Pflege: Frank Parussel / [153er-netz.de](https://153er-netz.de/seiten/entwicklung/fhem.html).
Lizenz: GPL-2.0-or-later, siehe [LICENSE](LICENSE).
