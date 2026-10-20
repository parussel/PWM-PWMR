# PWM / PWMR – extended FHEM version

This is a compatible, independently installable extension of FHEM’s original
`94_PWM.pm` and `93_PWMR.pm` modules for pulse-width-modulated heating and
room control.

It is the first public 153er-netz.de edition and **not** an official FHEM
module. Back up FHEM first and monitor a heating system after any change.

The package always installs both partner files. It retains original FHEM
attribution and adds maintained 2026 extensions: 0.1 K target-temperature
selection, simpler window-contact configuration, a service valve override,
safe D-buffer handling, and confirmed `readingsProxy` switching. A proxy
command is acknowledged only after the reported `state` matches the requested
state; a command’s empty return value alone is not confirmation.

For installation, updates and rollback, use the German
[README](README.md). Its FHEM commands first exclude only the two official
module files, then subscribe to this project’s control manifest. The rollback
removes this source, removes only those two exclusions, and restores the
official modules.

Automated regression tests and an isolated FHEM-like environment were used
before publication. They do not verify a physical valve position, water flow,
or every third-party installation. See [NOTICE.md](NOTICE.md) and
[LICENSE](LICENSE).
