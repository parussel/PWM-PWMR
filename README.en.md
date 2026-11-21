# PWM / PWMR – extended FHEM version

This is a compatible, independently installable extension of FHEM’s original
`94_PWM.pm`, `93_PWMR.pm`, and the optional `98_FBHKeepAlive.pm` module for pulse-width-modulated heating and
room control.

It is the first public 153er-netz.de edition and **not** an official FHEM
module. Back up FHEM first and monitor a heating system after any change.

The package always installs both partner files. It retains original FHEM
attribution and adds maintained 2026 extensions: 0.1 K target-temperature
selection, simpler window-contact configuration, a service valve override,
safe D-buffer handling, and confirmed `readingsProxy` switching. A proxy
command is acknowledged only after the reported `state` matches the requested
state; a command’s empty return value alone is not confirmation.

`FBHKeepAlive` provides bounded per-room maintenance-pulse spacing from
filtered return temperatures. It learns only while the associated
`TempReadingFilter` reports `active`, and counts exactly one learning decision
per continuous valve opening. The filtered sample must be timestamped at or
after the active processing phase began; cached pre-delay values are rejected.
Pulse duration must exceed the configured filter delay. It retains fixed pulse duration and starts
from each room's existing static cadence, and automatically falls back to
the unchanged PWMR `maxOffTime` settings whenever data or provider output is
not usable. One generic instance is used per PWM group; an optional shared
coordination group prevents overlapping dynamic maintenance pulses. Shadow,
active, freeze, reset, diagnostics, and arbitrary outside-device/readings are
supported. See the German README for configuration and rollback commands.
A fresh outside-temperature change of at least 0.5 K is used only as a
bounded tie-breaker when room and return assessments are otherwise stable.
Coordination is claimed only at final PWM selection. A short reservation
bridges actuator confirmation, while reported active actors continue to block
overlap after that reservation expires.

For installation, updates and rollback, use the German
[README](README.md). Its FHEM commands first exclude only the two official
module files, then subscribe to this project’s control manifest. The rollback
removes this source, removes only those two exclusions, and restores the
official modules.

Automated regression tests and an isolated FHEM-like environment were used
before publication. They do not verify a physical valve position, water flow,
or every third-party installation. See [NOTICE.md](NOTICE.md) and
[LICENSE](LICENSE).
