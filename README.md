# Witty Pi 4 — driver and supervisor, POSIX shell, no vendor script

The [UUGear Witty Pi 4](https://www.uugear.com/product/witty-pi-4/) power
controller, driven in POSIX shell with systemd units — no `wiringPi`, no
GNU-`date` assumptions, no dependency on Raspberry Pi OS. Plus the layer that
makes it survive being left alone: a duty-cycle scheduler, a read-only
supervisor that repairs what it can, an audit tool and a shutdown gate.

The Witty Pi 4 is an ATtiny841 + PCF85063A HAT that gives a Pi a real-time
clock (±2 ppm), a 6-30 V DC/DC converter, and — the reason it exists — the
ability to cut its own power and wake itself later. That last part is what
makes an unattended, battery- or solar-powered node possible: the Pi is
*off*, not idle, for most of the day.

## Why not the vendor's script

UUGear ships `utilities.sh` — nearly 700 lines that assume Raspberry Pi OS.
Essentially none of it runs on anything else:

- it calls `wiringPi`'s `gpio` at two dozen sites (deprecated upstream)
- it relies on GNU `date` semantics at dozens more, where busybox/ash differs
- it reads and rewrites `/boot/config.txt`, which may not even be writable
- it greps `/etc/os-release` to decide which Raspberry Pi OS release it's on

What's actually needed is small: read and write registers on an I²C slave,
and drive two GPIO lines. That's `wittypi-lib.sh` — an independent
implementation, not a port. The register numbers come from the vendor's
MIT-licensed firmware source, cross-checked against the User Manual, with
every disagreement between the two recorded in [`WITTYPI.md`](WITTYPI.md).
Where they disagree, the firmware wins.

## What's in here

| | What |
|---|---|
| `wittypi-lib.sh`, `wittypi`, `wittypi-daemon`, `wittypi-before-shutdown` | the driver itself: register access, the CLI, the boot-time daemon, and the pre-shutdown gate |
| `wittypi-schedule`, `wittypi-watch`, `wittypi-audit`, `wittypi-shutdown-gate` | the supervisor layered on it — see below |
| `timing-windows`, `timing-terms` | the timing-budget report, and the measured/firmware constants it reads |
| [`systemd/`](systemd/) | every unit, driver and supervisor alike |
| [`boards/`](boards/) | the per-board calibration registry — see below |
| [`firmware/wittypi/`](firmware/wittypi/) | a firmware patch for the ATtiny841 itself, and the tooling to back up a controller before flashing it |

This repo ships plain files and systemd units, with no build system of its
own — install them however suits yours. A Yocto layer wrapping them exists but
is not published; the install paths every script and unit expects are the ones
in `systemd/` and `/usr/libexec/site/`, so packaging it is a `do_install` and
nothing more.

### The supervisor

The driver talks to the controller. The supervisor keeps a node that is
*unattended* actually coming back:

- **`wittypi-schedule`** — the duty-cycle scheduler. Given an awake and an
  asleep window in `/data/wittypi-schedule.env`, it arms both alarms from the
  controller's own RTC. It anchors appointments on absolute cycle phase, not
  on "now", so re-running it mid-window recomputes the *same* two instants —
  which is what makes it safe for anything else to re-run as a repair. Absent
  that file it is a clean no-op, so a hand-scheduled node is unaffected.
- **`wittypi-watch`** — a read-only supervisor on a 15-minute timer. It checks
  the guaranteed-wake register, the alarm state, RTC plausibility against a
  synced system clock, and whether a configured node's shutdown appointment is
  actually armed. It writes no register: where a repair is already owned by
  another unit it asks that unit to run, bounded to three attempts per boot.
- **`wittypi-audit`** — everything the supervisor knows, on one screen, for a
  human at a serial console.
- **`wittypi-shutdown-gate`** — makes a typed `poweroff` arm a wake first. It
  never blocks a shutdown; it only decides how loudly one proceeds.

### Timing budgets

`timing-windows` reads every timing constant from the file that uses it and
prints the relationships between them — most importantly that the shutdown
sequence fits inside the controller's power-cut delay. It reports on terms it
does not own (your image's watchdog, boot-health and A/B settings) as `?`
rather than guessing; point it at them with `WITTYPI_TIMING_SITE_DIR`,
`WITTYPI_TIMING_UNIT_DIR`, `WITTYPI_TIMING_WATCHDOG`, `WITTYPI_TIMING_NTPCONF`,
`WITTYPI_TIMING_ABCONF` and `WITTYPI_TIMING_BOOTCMD`.

The measured constants in `timing-terms` (`T_BOOT`, `T_MARKGOOD`) describe the
*image*, not the Witty Pi. Re-measure them for your own build before trusting
any margin computed from them.

### Optional integration: `wake-guard` and `notify`

Two hooks are reached by path and are **not** part of this repo:

| Hook | Default path | What it does |
|---|---|---|
| `wake-guard` | `/usr/libexec/site/wake-guard` | arms alarm1 before the rail is cut |
| `notify` | `/usr/bin/notify` | pushes a message off the node |

Every call site has an explicit branch for their absence, so a node without
them still shuts down safely and says plainly that no wake was armed. Supply
your own via `WITTYPI_SHUTDOWN_GATE_WAKE_GUARD` / `WITTYPI_WATCH_WAKE_GUARD`
and `WITTYPI_WATCH_NOTIFY`.

**On battery with no `wake-guard`, nothing arms alarm1.** The shutdown gate
says so on every power-off; the controller's guaranteed wake (26 h) is then
the only thing that brings the node back.

**Read [`firmware/wittypi/README.md`](firmware/wittypi/README.md) before
touching the firmware.** Flashing the controller destroys the RTC crystal
calibration permanently unless you back it up first, and there's no way to
recover that value except by re-measuring against a reference clock over
hours.

### Per-board calibration

`boards/` is a registry keyed by the Pi's
`/proc/cpuinfo` serial, because the HAT has no readable serial of its own —
a Pi and its HAT are a bonded pair. `example.env` shows the shape;
`README` in that directory has the procedure. The values in `example.env`
are placeholders with the right shape and deliberately wrong content:
copying them onto a real board gives you a miscalibrated clock that looks
like it's working.

## Documentation

[`WITTYPI.md`](WITTYPI.md) is the reference — the register map, the design
pattern for making an unattended wake reliable, and what a wrong value
costs. [`WITTYPI-SETTINGS.md`](WITTYPI-SETTINGS.md) covers the settings to
apply and calibration. [`WITTYPI-ALARM1.md`](WITTYPI-ALARM1.md) covers the
wake alarm in detail — the register states, the write/clear ordering, and
the edge cases.

## Tests

```sh
./tests/lint.sh && ./tests/run.sh
```

~650 assertions, host-side only — no I²C, no hardware, no root, no network.
They run the shipped scripts against fixtures with `i2cget`/`i2cset`/
`systemctl` stubbed on `PATH`. A green run means the logic is right; it
never means it works on the board.

Cases that reference something this repo doesn't own print a visible `SKIP`
naming it, and a run where *nothing* asserted anything fails rather than
reporting OK. A few cases assert how these files get packaged, which is a
question this repo cannot answer on its own: point them at your own recipes
with `WITTYPI_YOCTO_RECIPE`, `WITTYPI_YOCTO_OPS_RECIPE` and
`WITTYPI_YOCTO_IMAGE_RECIPE`, or let them skip.

## Licence

MIT. The upstream Witty Pi 4 software this interoperates with is also MIT
(Dun Cat B.V. / UUGear). The firmware patch under `firmware/` applies to
their `WittyPi4.ino`.
