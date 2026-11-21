# Heizungsregelkette Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die GitHub-Seite um eine zentrale, technisch korrekte Beschreibung der gesamten Heizungsregelkette ergänzen.

**Architecture:** Eine neue zentrale Markdown-Datei trägt den ausführlichen Inhalt. README und Betriebswissen verweisen beziehungsweise dokumentieren den passenden Ausschnitt, ohne Modulcode zu verändern.

**Tech Stack:** Markdown, JSON, FHEM-Dokumentation, GitHub

**Spec:** `docs/superpowers/specs/2026-11-21-regelkette-design.md`

## Global Constraints

- GitHub-Dokumentation ausschließlich deutsch.
- PWMK bleibt hardware- und hydraulikunabhängig.
- I²C und OneWire dürfen nicht verwechselt werden.
- Shelly Plus Add-on unterstützt laut Hersteller bis zu fünf DS18B20.
- Keine Änderung an laufender Regelungslogik oder Modulcode.

## Review Focus

- Konkreter Anlagenaufbau darf nicht als allgemeine Voraussetzung erscheinen.
- TempReadingFilter muss als Voraussetzung belastbarer Rücklaufbewertung erklärt sein.
- PID20 darf nicht fälschlich als zwingende PWMK-Abhängigkeit erscheinen.
- I²C darf keine pauschale Maximallänge erhalten.
- Links und Update-Metadaten müssen nach der Veröffentlichung funktionieren.

---

### Task 1: Zentrale Anlagen- und Modulbeschreibung

**Files:**
- Create: `HEIZUNGSREGELKETTE.md`
- Modify: `README.md`
- Modify: `CHANGED`
- Modify: `controls_pwm-pwmr.txt`

- [ ] Zentrale Dokumentation mit Problem, Messprinzip, Praxisaufbau, Alternative und Modulverbund schreiben.
- [ ] README-Einleitung ergänzen und zentralen Link vor der Installation platzieren.
- [ ] Änderungsnachweis und Update-Metadaten aktualisieren.
- [ ] Links, deutsche Sprache und technische Aussagen prüfen.

### Task 2: Betriebswissen und Veröffentlichung

**Files:**
- Modify: `/opt/fhem/mycfg/dokumentation/betriebswissen.json`

- [ ] Konkrete Verkabelung, Busaufteilung, Messmontage und Alternativweg als neuen Wissenseintrag ergänzen.
- [ ] JSON validieren und ohne FHEM-Neustart einspielen.
- [ ] Repository-Diff prüfen, committen und auf `main` veröffentlichen.
- [ ] Veröffentlichte README, zentrale Datei und Controls-Datei abrufen und verifizieren.

