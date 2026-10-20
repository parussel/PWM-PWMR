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
