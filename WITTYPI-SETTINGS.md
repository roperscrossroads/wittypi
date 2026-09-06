# Recommended settings — Witty Pi 4

The configuration to apply, how to apply it, and how to prove it took.

**This file is the *what*. [`WITTYPI.md`](WITTYPI.md) is the *why*** — the
firmware reading, the register-by-register reasoning, the three-layer design
and the traps. Nothing here restates that; it links to it. When the two
disagree, `WITTYPI.md` is right and this file is stale.

The register values below are not a specification kept in prose. They are
what `wittypi configure` writes and `wittypi check` compares against. The
tool is the source of truth; this file records the *site decisions* that
feed it.

---

## 1. Site configuration

```sh
# /data/wittypi.env
WITTYPI_TOPOLOGY=usb5v            # decides registers 19, 22, 41
WITTYPI_POWER_CUT_DELAY=20        # the shutdown budget          (max 25)
WITTYPI_GUARANTEED_WAKE=26        # layer 3, must exceed the cycle
WITTYPI_DEFAULT_ON_DELAY=10       # max 32 — see the warning below
```

Three of these four are bounded from above, each for a firmware-level
reason: 25 because register 21 is x10 s in a byte and 255 is the "never
written" sentinel; 26 because a 24 h backstop should not race a once-daily
wake; 32 because the firmware multiplies the delay in a 16-bit int (§2). A
value chosen only for "large enough" has been wrong here more than once.

**`WITTYPI_TOPOLOGY` is the one that matters** — it decides registers 19, 22
and 41 and nothing else. Every other value has a correct default, and
`/data` survives updates, so a node is configured once and every subsequent
image honours it.

**`WITTYPI_POWER_CUT_DELAY`** is how long the controller waits after a
shutdown *request* before cutting the rail — the whole of Linux shutting
down has to fit inside it, plus any health-check grace period you run. The
factory default (15, i.e. 1.5 s) leaves little margin for that; raising it
costs a small amount of standby current per cycle.

**The maximum usable value is 25, not 25.5.** Register 21 is x10 seconds in
a byte, so 25.5 would store 255 — the sentinel the MCU reads as "never
written" and replaces with its compiled default on the next power loss. The
delay would appear to work until the first power interruption and then
silently vanish, on exactly the path it exists for.

`WITTYPI_TOPOLOGY` unset is handled deliberately rather than silently:

| `WITTYPI_TOPOLOGY` | register 7 (actual topology) | behaviour |
|---|---|---|
| set | any | applies the full policy |
| unset | 1 (VIN) | **refuses, exit 2** — writes nothing; those registers are the pack's protection |
| unset | 0 (USB-C) | warns and applies the topology-independent rows |

A row count is not a pass: with a topology set the policy is 14 rows (12
without), and each `ADJ_*` trim adds one. `check` reporting "in sync" over a
smaller row count than you expect usually means the topology was never set.

The unit applies this on **every boot** (`wittypi-configure.service`, before
`wittypi.service`). The controller's registers live in the ATtiny's EEPROM,
which nothing else in this repo builds or reviews, so the image asserts the
policy rather than trusting what a board happens to hold — a replacement
Witty Pi arrives at factory defaults, and without this step a board on a
battery topology would have no low-voltage protection and no layer-3 wake.

### The other topologies

| Pack | `WITTYPI_TOPOLOGY` | Notes |
|---|---|---|
| 5 V supply / USB power bank | `usb5v` | |
| 3S Li-ion on the XH2.54 input | `vin3s` | |
| 2S Li-ion on the XH2.54 input | `vin2s` | dropout point depends on your charger board |

`vin2s`/`vin3s` accept `WITTYPI_LOW_VOLTAGE` and `WITTYPI_RECOVERY_VOLTAGE`
overrides; `usb5v` refuses them, since in that mode they configure nothing
while reading as if they were protection.

An unrecognised topology is refused rather than defaulted — a typo that
quietly left the battery unprotected would otherwise look like a working
node.

---

## 2. What `wittypi configure` changes from factory defaults

Six writes, seven registers already correct — derived from
`initializeRegisters()` (`WittyPi4.ino:268-296`):

| Reg | Factory | Policy | |
|---|---|---|---|
| 17 `DEFAULT_ON` | 0 | **1** | set |
| 47 `DEFAULT_ON_DELAY` | 0 | **10** (max 32) | set |
| 20 `BLINK_LED` | 100 | **0** | set |
| 21 `POWER_CUT_DELAY` | 70 | site value from §1 | set |
| 45 `OVER_TEMP_ACTION` | 0 | **1** | set |
| 46 `OVER_TEMP_POINT` | 80 | **70** | set |
| 49 `GUARANTEED_WAKE` | 0 | **26** | set |
| 19, 22 | 255, 255 | 255, 255 | ok on a USB-C topology — see §3 for why 255 is safe there |
| 23, 41, 43, 48 | 0 | 0 | ok |

A successful `wittypi configure` / `wittypi check` run reports something
like:

```
  ok    19  low voltage (x10 V)                    255
  ok    22  recovery voltage (x10 V)               255
  ok    41  ignore power mode                      0
  ok    17  default-on after a power interruption  1
  ok    47  default-on delay (s)                   10
  ok    20  white LED while asleep (ms)            0
  ok    23  dummy load while asleep (ms)           0
  ok    21  power-cut delay (x10 s)                200
  ok    45  over-temperature action (1 = shutdown) 1
  ok    46  over-temperature point (C)             70
  ok    43  below-temperature action (0 = nothing) 0
  ok    48  misc (alarm1 delay enabled)            0
  ok    49  guaranteed wake (h)                    26
in sync — all 13 policy registers match.
```

Exit 0. Check the row count, not just the verdict — "in sync" over fewer
rows than your policy actually defines (e.g. because a topology was never
set) looks identical to a correct run.

Registers 44 (`BELOW_TEMP`) and 46 (`OVER_TEMP_POINT`) are a pair: setting
one without the other can leave the unconfigured half at its factory value
while `check` still reports everything in sync, because a register outside
the declared policy is invisible to the comparison. Keep both in the same
policy list.

Four gotchas worth knowing without reading the full firmware trace:

- **`BLINK_LED=0`** stops the white LED blinking 100 ms every 4 s while
  asleep — a meaningful fraction of standby current if the board sleeps
  most of the day.
- **`DEFAULT_ON_DELAY` must never exceed 32.** `WittyPi4.ino:253` runs
  `delay(reg * 1000)` in a 16-bit `int` on the AVR, so the product wraps
  *before* being widened to `delay()`'s `unsigned long`. Anything ≥33
  becomes roughly 49.7 days, and `DEFAULT_ON` never fires: input power
  returns and the board stays dark, recoverable only by the physical button
  (guaranteed wake and alarm1 both live in the branch this path never
  reaches). The vendor's own tool accepts 0-10; this tooling refuses above
  32, and refuses 255 separately, since the MCU treats a stored 255 as
  "never written" and substitutes its compiled default.
- **`OVER_TEMP_ACTION=1`** is the action bit — without it, a configured trip
  *point* does nothing, because the action that would fire on it is off.
- **`GUARANTEED_WAKE` must exceed the longest intended sleep.** Set shorter
  than or equal to the normal duty cycle, layer 3 fires every cycle instead
  of only when a scheduled wake has actually failed.

### Calibration trims (registers 24-26) — per-board, not site config

These don't belong in `/data/wittypi.env` — they calibrate one physical
board's ADC and RTC crystal, so they belong in the per-board registry
described in [`boards/README`](boards/README), not in site-wide config.

To calibrate: read the uncalibrated values with `wittypi status`, measure
the real values with a multimeter (RTC offset against a reference clock;
Vout/Vin at the Witty Pi's own pads, not upstream of any cabling; Iout via
the shunt formula in the firmware source), compute the trim, apply it with
`wittypi set`, and confirm the corrected reading matches your meter. Treat a
single-point current calibration off a small shunt signal as an estimate,
not a precise value — cross-check against an inline meter before it feeds
any power budget.

Trims applied live with `wittypi set` are held only in the MCU's I2C
registers. `wittypi-configure.service` re-derives every register from
`/data/wittypi.env` plus the board registry on every boot, so a live trim
that isn't also committed to the board registry file is reverted on the
next reboot.

---

## 3. What the board cannot do on a 5 V feed

Feeding USB-C puts the controller in `POWER_MODE 0`, and four firmware gates
turn off with it (`WITTYPI.md` has the full mechanism):

| Behaviour | Gate | In mode 0 |
|---|---|---|
| Low-voltage shutdown | `:962` | never fires |
| Voltage-restore recovery wake | `:406` | never fires |
| Wake suppressed on a flat battery | `:824` | always wakes |
| Guaranteed wake's voltage check | `:364` | skipped — fires unconditionally |

Knock-on effects:

- Register 8 (`LV_SHUTDOWN`) reads 0 forever — in mode 0 it can only ever be
  cleared, never set.
- Reason codes 4 (`LOW_VOLTAGE`) and 5 (`VOLTAGE_RESTORE`) never occur.
- Registers 19, 22, 41 and 42 are meaningless — the XH2.54 connector, the
  DC/DC converter and the associated voltage floor are all out of the
  picture.
- Vin telemetry changes meaning rather than disappearing: on USB-C it reads
  the upstream 5 V rail, a brownout indicator rather than a state of charge.

Everything else works normally: the RTC and alarms, temperature actions (no
reference to power mode at all), `DEFAULT_ON`, the power-cut delay and TXD
watching, the GPIO-4/17 sequencing, the button, `Vout`/`Iout` telemetry, and
the CR2032 backup.

---

## 4. On a USB-C/mode-0 topology, nothing on the controller protects the battery

Every wake path ignores pack voltage on this topology: the daily scheduled
wake because `canTriggerAlarm()` returns early in mode 0, and guaranteed
wake because its own voltage check is skipped. The board will wake on
schedule and run its full window on a nearly-flat battery, and no register
changes that. If you're powering from a battery through a 5 V regulator
rather than the Witty Pi's own VIN input, you need protection outside the
controller. Three mitigations, in the order they matter:

### 4.1 Gate upstream — the charger/regulator board's own low-voltage disconnect

You can't gate inside the Witty Pi on this topology, so gate before it. A
charger/regulator board that cuts its 5 V output below a pack threshold
leaves the controller unpowered, and no wake path of any kind can fire. When
the pack recovers past the reconnect threshold, the 5 V returns, the MCU
re-initialises, and `DEFAULT_ON=1` brings the board up after the configured
delay.

This needs real hysteresis or it chatters — a typical target is disconnect
around 3.0 V/cell, reconnect around 3.4-3.6 V/cell. A short, repeated
power-on/off cycle at the reconnect threshold can also interact badly with
any boot-attempt-counting mechanism elsewhere in the system (an A/B update
watchdog, for example) — size the hysteresis with that in mind, not just the
battery.

### 4.2 Make a bad wake cheap rather than preventing it

Immediately after arming the next alarm, read pack voltage some other way if
the controller's own telemetry doesn't cover it on your topology (e.g. a
peripheral with its own ADC over USB). Below a floor you choose, rewrite the
alarm further out and power off immediately, bounding the cost of a bad wake
to well under the length of a normal awake window.

Fallback: the controller's own `Vin`, which on this topology reads the 5 V
rail rather than the battery — still useful as a "the supply is struggling"
signal even though it isn't state of charge.

### 4.3 Don't disable guaranteed wake to work around this

Setting `GUARANTEED_WAKE=0` removes the only defence against the board dying
before it ever writes an alarm — and buys back very little runtime, since
the guaranteed-wake counter resets on every power-on. Layer 3 only fires
once a scheduled wake has already failed, which is exactly when it's wanted.

---

## 5. What must exist off the board

| | Why |
|---|---|
| Charger/regulator LVD, with hysteresis | §4.1 — the only autonomous battery protection on a USB-C/mode-0 topology. |
| CR2032 fitted (not a rechargeable LIR2032) | Without it, a pack collapse resets the RTC to 2000-01-01, and a stored alarm ends up roughly 13 days in the RTC's future. |
| A way to read pack voltage from outside the controller | §4.2, if the controller's own Vin doesn't reflect the pack on your topology. |
| A wake window timed to production/thermal conditions | For a solar-powered install, running while the panel is producing avoids an extra charge/discharge round trip, and offsetting the window from peak sun avoids the hottest part of the day for both the electronics and the cells. |
| Shade or ventilation for the enclosure | Calendar aging, not the power budget, is usually the multi-year risk — Li-ion held near full charge at high temperature loses capacity fast, and no controller register affects it. Lowering the charger's float voltage a little (e.g. 4.05-4.10 V/cell instead of 4.20) roughly doubles calendar life if your charger supports it. |

---

## 6. Commissioning, in order

1. Fit the CR2032, then power the board.
2. `wittypi status` — confirm the firmware id/revision you expect and
   `guaranteed wake available`. An older firmware revision may not have
   layer 3 (guaranteed wake) at all.
3. Write `/data/wittypi.env` with the settings from §1.
4. `wittypi configure` (or reboot — the unit runs it automatically).
5. `wittypi check` — expect `in sync` with the full row count for your
   topology (14 with `ADJ_*` trims and a below-temp policy, 12 with none).
   Check the count as well as the verdict, and check it in the journal
   (`journalctl -u wittypi-configure`) rather than a hand-typed `wittypi
   check` — a shell invocation can inherit a different environment than the
   unit and report a different row count for the same board.
6. `wittypi rtc-write` once the system clock is known good, then
   `wittypi rtc` to read it back and confirm.
7. Verify a connected console adapter isn't holding TXD high with the board
   powered off — measure GPIO-14 to ground, or leave the adapter's VCC
   disconnected. An adapter holding TXD high means the rail is never
   actually cut.

Exit codes: 0 = in sync or applied · 1 = no controller found on the bus
(treated as success by the unit, since that's the normal case on a bench
without the HAT attached) · 2 = the configuration is contradictory, or a
register refused to take the requested value.

---

## 7. Open — measure before trusting

- **The charger/regulator board's cutoff and reconnect voltages.** §4.1
  depends entirely on them; measure rather than assume.
- **`Iout` calibration is an estimate, not a precise value** (see §2) —
  cross-check against an inline meter before it feeds a power budget.
- **`T_boot` on your specific board and image**, if it factors into your
  awake-window budget.
- **Whether the DC/DC is truly out of circuit on USB-C.** Measure VIN to
  GND at the unpopulated power header with the XH2.54 empty.
- **Schedule renewal.** Alarm1 fires once; registers 27-31 hold one
  appointment and nothing on the controller itself renews it — rearming for
  the next cycle is the supervisor's job (see `WITTYPI-ALARM1.md`).
