# Heizungsregelkette – Sensorik, Bodenerhaltung und Mischerregelung

Diese Seite beschreibt den praktischen Hintergrund der erweiterten
FHEM-Heizungsregelung. Sie zeigt, warum `TempReadingFilter` und `PWMK`
entstanden sind und wie die verschiedenen Module zusammenarbeiten. Die
beschriebene Hydraulik ist ein erprobtes Praxisbeispiel, aber keine feste
Voraussetzung für den Einsatz der Module.

## Das ursprüngliche Problem

Eine klassische PWM-/PWMR-Regelung schließt das Ventil eines Raumes, sobald
seine Solltemperatur erreicht ist. Öffnet das Ventil erst wieder, nachdem die
Raumtemperatur den Sollwert unterschritten hat, kann der Estrich bereits viel
Energie verloren haben. Bei einer trägen Fußbodenheizung dauert das spätere
Wiederaufheizen entsprechend lange.

Das ist nicht nur eine Komfortfrage. Ein stark ausgekühlter Heizkreis nimmt
beim erneuten Öffnen viel Energie auf. Dadurch können der gemeinsame Vorlauf,
ein vorgeschalteter Wärmetauscher und weitere Heizkreise deutlich einbrechen.
Ein pauschaler Erhaltungspuls hilft, passt aber nicht zu jedem Raum: Fläche,
Estrich, Fenster, Außenwände, Solltemperatur und Fremdwärme unterscheiden sich.

PWMK ersetzt deshalb nicht die Raumregelung. Das Modul verändert ausschließlich
den zeitlichen Abstand der Erhaltungspulse eines PWMR-Raums. Die Pulsdauer
bleibt fest und muss lang genug sein, um einen belastbaren Rücklaufwert zu
erhalten.

## Warum ein stehender Rücklaufwert nicht genügt

Die Bodentemperatur lässt sich in einer bestehenden Anlage meist nicht direkt
im Estrich messen. Ein sinnvoller Ersatz ist die Rücklauftemperatur des
einzelnen Heizkreises. Sie ist jedoch nur dann aussagekräftig, wenn Wasser aus
dem Boden tatsächlich bis zum Heizkreisverteiler zurückgeflossen ist.

Ohne Zirkulation nimmt das stehende Wasser zunehmend die Temperatur von Rohr,
Verteiler und Umgebung an. Selbst ein sorgfältig montierter Sensor liefert dann
keinen verlässlichen Wert für den Energiezustand des Bodens. Dieses Problem
betrifft Anlegefühler ebenso wie Tauchfühler an einer Stelle ohne aktuellen
Durchfluss.

`TempReadingFilter` löst genau diesen zeitlichen Zusammenhang:

```text
Ventil öffnet
    ↓
Wasser aus dem Heizkreis beginnt zu zirkulieren
    ↓
hydraulische Transport- und Filterzeit verstreicht
    ↓
Rücklaufwert wird als belastbar freigegeben
    ↓
PWMK bewertet Raum und Rücklauf
    ↓
nächster Erhaltungspuls wird früher oder später vorgesehen
```

Pro zusammenhängender Ventilöffnung übernimmt PWMK höchstens einen solchen
Messzyklus. Zwischengespeicherte Werte und Aktualisierungen bei geschlossenem
Ventil werden nicht als neue Bodentemperatur gelernt.

## Franks konkrete Anlage

Die vorhandene Fußbodenheizung verwendet den üblichen Verbund aus `PWM` und
`PWMR`. PWMR bestimmt den Wärmebedarf je Raum und steuert die thermischen
Stellantriebe der Heizkreise. PWM verteilt die Laufzeiten.

Hydraulisch liegt in dieser Anlage ein gemeinsamer Wärmetauscher vor den beiden
Etagen. Ein `PID20`-Regler steuert dessen Mischer. Hinter dem Wärmetauscher
liegen ein Mischer für das Untergeschoss und ein Mischer für das Obergeschoss,
die ebenfalls mit PID20 nach der jeweiligen Vorlauftemperatur geregelt werden:

```text
Pufferspeicher
    ↓
Wärmetauscher + PID20 + Mischer
    ↓
gemeinsamer FBH-Vorlauf
    ├── PID20 + Mischer Untergeschoss → PWMR-Heizkreise EG
    └── PID20 + Mischer Obergeschoss  → PWMR-Heizkreise OG
```

Diese Kaskade erklärt, warum die Wiederöffnung eines stark ausgekühlten Kreises
auch die anderen Regelkreise beeinflussen kann. Andere Anlagen können direkt
von einer Wärmequelle, nur über einen Mischer oder mit einer vollständig
anderen Hydraulik versorgt werden. Für PWMK ist diese konkrete Kaskade nicht
erforderlich.

## Montage der Rücklaufsensoren

An den aus dem Boden kommenden Rücklaufleitungen sitzen DS18B20-Anlegefühler.
Jeder Sensor ist mit zwei Kabelbindern fest an das Rohr gespannt. Eine
zusätzliche Isolierung um Rohr und Fühler vermindert den Einfluss der Luft im
Heizkreisverteiler. Entsprechend können auch Vorlauftemperaturen erfasst werden.

Die Montage verbessert die Messung, beseitigt aber nicht das Durchflussproblem.
Erst das Zusammenspiel aus Ventilöffnung, ausreichend langer Pulsdauer und
`TempReadingFilter` macht den Wert für PWMK hydraulisch belastbar.

## Getrennte Daten- und Aktorbusse

Die OneWire-Sensorik und die Ventilansteuerung sind zwei getrennte Systeme:

- Die DS18B20-Sensoren laufen über OneWire und zwei Instanzen des angepassten
  `OW2S0SMSGUARD`. Die zeitkritischeren allgemeinen Heizungswerte werden
  schneller abgefragt; die trägeren Rücklaufwerte der Fußbodenheizung dürfen
  ein gröberes Zeitraster verwenden.
- Die Stellantriebe werden über MCP-I/O-Bausteine angesteuert. Deren
  I²C-Verbindung zum Raspberry Pi wird für die längere Leitungsstrecke über
  geeignete Bus-Extender geführt und am entfernten Ende wieder auf normales
  I²C umgesetzt.

I²C besitzt keine allgemeingültige Maximallänge in Metern. Maßgeblich sind
Buskapazität, Leitung, Pull-ups, Geschwindigkeit, Teilnehmer und Umgebung. Die
I²C-Spezifikation nennt für Standard- und Fast-Mode üblicherweise eine maximale
Buskapazität von 400 pF. Geeignete Extender teilen oder übersetzen den Bus und
ermöglichen dadurch längere Strecken. Eine fremde Anlage muss deshalb nach
ihrem verwendeten Extender und Leitungsaufbau ausgelegt werden.

## Alternative Nachrüstung mit Shelly und MQTT

Eine kabelgebundene I²C-/MCP- und OneWire-Installation ist keine Voraussetzung.
Wenn im Heizkreisverteiler eine geeignete Stromversorgung vorhanden ist, können
beispielsweise kompatible Shelly-Plus-Geräte mit Shelly Plus Add-on verwendet
werden. Das Add-on unterstützt laut Hersteller bis zu fünf DS18B20-Sensoren.
Die Temperaturwerte können anschließend per MQTT als FHEM-Readings bereitstehen.

Bei neun Heizkreisen könnten rein von der Sensoranzahl her zwei Add-ons
ausreichen. Vor einer Umsetzung müssen jedoch das konkrete Shelly-Grundgerät,
Spannungsversorgung, elektrische Sicherheit, Platz, Funkabdeckung,
Leitungslängen und MQTT-Konfiguration geprüft werden. Wer bereits Shellys zur
Ventilansteuerung verwendet, kann die Sensorik gegebenenfalls am selben System
ergänzen.

PWMK ist nicht auf OneWire festgelegt. Es benötigt passende FHEM-Devices und
frische numerische Readings. Deshalb können auch MQTT-, Modbus- oder andere
Sensorketten verwendet werden.

## Der vollständige Modulverbund

Die sechs Bausteine erfüllen unterschiedliche Aufgaben:

1. [`OW2S0SMSGUARD`](https://github.com/parussel/OW2S0SMSGUARD) liest die
   OneWire-Sensoren und prüft auffällige Messsprünge auf Plausibilität.
2. [`TempReadingFilter`](https://github.com/parussel/TempReadingFilter) gibt
   den Rücklauf erst nach der hydraulisch notwendigen Laufzeit frei.
3. [`PWM`](https://github.com/parussel/PWM-PWMR) verteilt die zeitlichen
   Anforderungen der Räume.
4. [`PWMR`](https://github.com/parussel/PWM-PWMR) bewertet Solltemperatur,
   Raumtemperatur und Aktor eines einzelnen Raums.
5. [`PWMK`](https://github.com/parussel/PWM-PWMR) lernt aus Raum- und gültigem
   Rücklaufwert einen begrenzten, dynamischen Erhaltungspulsabstand.
6. [`PID20`](https://github.com/parussel/PID20) regelt in Franks Anlage die
   vorgelagerten Mischer und damit die benötigten Vorlauftemperaturen.

Für den Grundbetrieb genügen PWM und PWMR. PWMK ist eine optionale Erweiterung
und setzt für die Rücklaufbewertung TempReadingFilter voraus. OW2S0SMSGUARD ist
nur bei der entsprechenden OneWire-Anbindung erforderlich. PID20 gehört zur
beschriebenen Gesamtanlage, ist aber keine technische Voraussetzung für PWMK.

## Regelkette im Betrieb

```text
Raumtemperatur + Sollwert
            ↓
           PWMR ───────────────→ Raumventil
            ↑                         ↓
PWM-Zeitplanung                  Heizkreis durchströmt
                                      ↓
OW2S0SMSGUARD → TempReadingFilter → gültiger Rücklauf
                                      ↓
                                    PWMK
                                      ↓
                         dynamischer Pulsabstand an PWMR

Außentemperatur / Heizkurve → PID20 → Vorlauftemperatur und Mischer
```

Jedes Modul bleibt für seine Aufgabe verantwortlich. Bei fehlendem oder
ungültigem PWMK-Ergebnis verwendet PWMR weiterhin den statischen
`maxOffTime`-Wert. Dadurch bleibt die Regelung abwärtskompatibel und besitzt
eine klar definierte Rückfallebene.

## Technische Quellen

- [NXP: I²C-bus specification and user manual](https://www.nxp.com/docs/en/user-guide/UM10204.pdf?locale=de)
- [Shelly Plus Add-on – offizielle Dokumentation](https://www.shelly.com/blogs/documentation/shelly-plus-add-on/)

