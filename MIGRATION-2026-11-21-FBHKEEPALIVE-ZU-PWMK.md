# Einmalige Umstellung der Rohfassung FBHKeepAlive auf PWMK

Diese Kurzanleitung gilt **nur**, wenn am 21.11.2026 zwischen der ersten
Rohveröffentlichung am Nachmittag und der Umbenennung am Abend bereits
`FHEM/98_FBHKeepAlive.pm` installiert und ein Gerät vom Typ `FBHKeepAlive`
definiert wurde. Für Neuinstallationen gilt die normale [README](README.md).

## Ziel

- `98_FBHKeepAlive.pm` wird durch `95_PWMK.pm` ersetzt.
- Der Modultyp lautet `PWMK`, ausgeschrieben „PWM KeepAlive“.
- Bereits gespeicherte Lernwerte können weiterverwendet werden.

## Vorgehen

1. FHEM-Konfiguration und vorhandene `FBHKeepAlive_*.json` sichern.
2. Neue Dateien installieren:

```text
update check https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
update all https://raw.githubusercontent.com/parussel/PWM-PWMR/main/controls_pwm-pwmr.txt
```

3. Attribute der alten Provider notieren, besonders `mode`, Intervallgrenzen,
   `coordinationGroup`, `minPulseDuration` und `stateFile`.
4. Neue Provider mit denselben Einstellungen definieren, zum Beispiel:

```text
define PWMK_EG PWMK PWM_EG Temperatur_Aussen:realtemperature
attr PWMK_EG room System
attr PWMK_EG group PWM
attr PWMK_EG mode active
```

5. Bei allen PWMR-Räumen `floorKeepAliveProvider` auf den neuen Namen ändern.
6. Für den Erhalt der Lernhistorie beim neuen Provider den bisherigen
   vollständigen `stateFile`-Pfad eintragen. PWMK prüft die Datei beim Laden.
7. FileLogs auf neuen Gerätenamen und `PWMK`-Dateinamen umstellen.
8. Alte Definitionen erst löschen, wenn alle PWMR-Räume den neuen Provider
   verwenden und dessen Readings sichtbar sind.
9. Neustarten und Räume, Modus, `persistenceStatus`, `confidence_*`,
   `fallback_*` sowie `keepAliveMode` der PWMR-Räume kontrollieren.
10. Erst danach `/opt/fhem/FHEM/98_FBHKeepAlive.pm` manuell löschen.

```text
save
shutdown restart
```

Die alte Datei wird nicht weiter ausgeliefert, damit nicht zwei Module mit
derselben Aufgabe parallel geladen werden.
