# Zentrale Dokumentation der Heizungsregelkette

## Absicht

Die PWM-PWMR-Seite soll vor der Installation erklären, welches praktische
Problem PWMK löst, wie belastbare Rücklaufwerte entstehen und wie die
überarbeiteten FHEM-Module zusammenarbeiten. Anwender sollen die Lösung auf
andere Hydrauliken und Sensorwege übertragen können.

## Aufbau

Eine zentrale Datei `HEIZUNGSREGELKETTE.md` im PWM-PWMR-Repository enthält die
vollständige Beschreibung. Die README führt kurz in Problem und Modulverbund
ein und verweist dann auf diese Datei. Der Text unterscheidet die allgemeine
Funktionskette von Franks konkreter Anlage und nennt eine Shelly/MQTT-Alternative.

## Festgelegte Inhalte

- Problem: ausgekühlter Estrich trotz erreichter Raumtemperatur und starke
  Lastsprünge beim späteren Wiederaufheizen.
- Messproblem: Anlegefühler liefern ohne Durchfluss keinen belastbaren
  Rücklaufwert; TempReadingFilter wertet erst nach hydraulischer Laufzeit aus.
- Praxisaufbau: DS18B20 an Rücklaufrohren, Kabelbinder und Isolierung;
  OneWire getrennt von I²C/MCP; zwei unterschiedlich getaktete
  OW2S0SMSGUARD-Instanzen; Wärmetauscher mit nachgelagerten OG-/UG-Mischern.
- Alternative: geeignete Shelly-Plus-Geräte mit Plus Add-on, bis zu fünf
  DS18B20 je Add-on und Übertragung per MQTT.
- Modulverbund: OW2S0SMSGUARD, TempReadingFilter, PWM, PWMR, PWMK und PID20.
  PID20 und die konkrete Wärmetauscherhydraulik sind keine PWMK-Pflicht.
- I²C wird nicht mit einer pauschalen Maximallänge beschrieben; maßgeblich
  sind Buskapazität, Leitung und Geschwindigkeit, bei Bedarf Bus-Extender.
- GitHub-Seite bleibt deutsch; bestehende Modulhilfen bleiben zweisprachig.

## Gewählter Ansatz

Zentrale Dokumentation statt mehrfach kopierter Texte. So bleibt der
Gesamtzusammenhang auffindbar, während Korrekturen nur einmal gepflegt werden.

