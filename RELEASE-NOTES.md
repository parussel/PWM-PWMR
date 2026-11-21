# Erste öffentliche 153er-netz.de-Version

Diese erste Veröffentlichung bündelt die zusammengehörigen, erweiterten
FHEM-Module `93_PWMR.pm` und `94_PWM.pm`.

## Enthaltener Funktionsumfang

Die veröffentlichte Version enthält die vorhandenen Erweiterungen für
0,1-K-Solltemperaturschritte, Fensterkontakte, Ventil-Service-Override und
robuste D-Pufferbehandlung.

## Korrektur: Schaltzustandsabgleich bei `readingsProxy`

Nur `93_PWMR.pm` wurde für diese Korrektur geändert. `94_PWM.pm` bleibt ein
erforderlicher Partner im Paket, ist gegenüber dem zugrunde liegenden eigenen
Stand unverändert und wird deshalb gemeinsam verteilt.

Ein über `readingsProxy` gesteuerter Ausgang konnte intern bereits als
geschaltet gelten, obwohl dessen `setFn` den Schaltbefehl nicht weitergegeben
hatte. Eine leere Befehlsrückgabe allein ist keine ausreichende Bestätigung.

- PWMR prüft nach einem Proxy-Schaltbefehl zusätzlich das Reading `state`.
  Bei fehlender oder widersprechender Rückmeldung wird der angeforderte
  Zustand nicht als erfolgreich geschaltet bestätigt; `lastswitch` bleibt
  unverändert.
- Beim normalen Einlesen verwendet PWMR das Proxy-Reading `state` statt des
  möglicherweise für die Oberfläche formatierten `STATE`. Der interne
  `actorState` wird daran angeglichen, ohne einen zusätzlichen Stellbefehl
  oder einen neuen Schaltzeitpunkt zu erzeugen.

Regelparameter, Solltemperaturen, PWM-Taktung und vorhandene Sperren werden
durch diesen Fix nicht geändert. Der Abgleich bestätigt ausschließlich den
gemeldeten Softwarezustand, nicht die mechanische Ventilposition oder den
tatsächlichen Durchfluss.
# 1.1.1-153er – 2026-11-21

Die Koordination dynamischer Erhaltungspulse wird jetzt erst bei der
endgültigen PWM-Auswahl beansprucht. Eine kurze Reservierung überbrückt die
Schaltbestätigung; danach verhindert der gemeldete aktive Aktorzustand eine
Überschneidung. Ein Lernwert muss nach Beginn der aktiven Filterphase gemessen
worden sein. Ungültige Raumwerte, veraltete Rückläufe, eine Pulsdauer kleiner
oder gleich der Filterverzögerung sowie eine nicht geladene Providerfunktion
führen nachvollziehbar auf den unveränderten statischen Wert zurück.

# 1.1.0-153er – 2026-11-21

Diese Version ergänzt `98_FBHKeepAlive.pm`. Das Modul lernt begrenzte
Erhaltungspulsabstände aus hydraulisch gültigen, gefilterten
Rücklauftemperaturen. Bestehende PWMR-Konfigurationen bleiben unverändert;
die Funktion wird je Raum ausdrücklich über zwei Attribute zugeordnet und je
Provider ausdrücklich aktiviert. Bei fehlenden, ungültigen oder veralteten
Daten greift automatisch der bisherige statische `maxOffTime`-Wert.

Empfohlener Ablauf: sichern, installieren, zunächst `mode shadow` prüfen,
danach `mode active` setzen und Diagnosereadings beobachten. Die bekannte
Installation verwendet wegen 600 Sekunden Filterverzögerung eine feste
Mindestpulsdauer von 20 Minuten.
