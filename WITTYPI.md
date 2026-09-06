# Power sequencing — Witty Pi 4

How the board sleeps and wakes, what the controller will and will not do on
its own, and the timing every design built on top of it has to fit inside.

Read from the source (`Witty-Pi-4/Firmware/WittyPi4/WittyPi4.ino`,
`Software/wittypi/`, from [uugear/Witty-Pi-4](https://github.com/uugear/Witty-Pi-4))
rather than from the product page. Every number that comes from the firmware
is cited by line; every number that is a budget rather than a measurement
says so.

> ## Check your firmware revision before trusting the defaults below
>
> The vendor's own User Manual and the firmware source describe different
> devices in places — this document was written from the firmware:
>
> | | Firmware (`WittyPi4.ino`) | Manual (older revisions) |
> |---|---|---|
> | `I2C_FW_REVISION` (reg 12) | `0x07` or higher | "default 1 or 3" |
> | Reg 49 | `I2C_CONF_GUARANTEED_WAKE` | "Reserved for future usage" on some manual revisions |
> | Reason codes | 0-12 (adds 10 `POWER_CONNECTED`, 11 `REBOOT`, 12 `GUARANTEED_WAKE`) | 0-8 on older revisions |
> | Reg 21 `POWER_CUT_DELAY` default | `70` → 7 s | `50` → 5 s, on older revisions |
>
> **Layer 3 below is guaranteed wake, and on firmware older than revision 7 it
> does not exist** — register 49 is inert and the board has two defences, not
> three. Check before relying on anything below:
>
> ```sh
> i2cdetect -y 1          # expect 0x08 on the Pi's bus — and see whether 0x51/0x48 also appear
> i2cget -y 1 0x08 0      # firmware ID, expect 0x26
> i2cget -y 1 0x08 12     # firmware REVISION — below 7 means no layer 3
> ```
>
> A board older than revision 7 can be reflashed over the ICSP header (item 7
> in the manual's interface diagram) with the `.ino.hex` in `Firmware/WittyPi4/`,
> using an ISP programmer — see "Reflashing the controller" below.
>
> ### `dtparam=i2c_arm=on` alone does not give you `/dev/i2c-1`
>
> `ENABLE_I2C`-style dtparams bring the **bus** up; the character device is a
> separate kernel config, `CONFIG_I2C_CHARDEV`, often shipped as a module
> (`=m`) rather than built in. `i2c-bcm2835` auto-loads because udev matches
> its device-tree compatible string to a modalias; `i2c-dev` is a userspace
> interface with no device to match, so udev has no reason to load it — which
> is why the vendor's own installer appends `i2c-dev` to `/etc/modules`. On a
> system that doesn't use `/etc/modules` (a custom-built kernel, an immutable
> image), build `CONFIG_I2C_CHARDEV=y` in rather than relying on autoload — on
> the bus that owns your board's power, a module that fails to load is one
> more silent way to lose control of it.

See also: [`WITTYPI-SETTINGS.md`](WITTYPI-SETTINGS.md) — the settings to
apply and how to verify them; this file is the reasoning behind them.
[`WITTYPI-ALARM1.md`](WITTYPI-ALARM1.md) — the alarm1 register, the
two-second match window, the once-only latch, the four register states
(including the half-written one), and the write/clear orderings.

---

## What the board actually is

| | |
|---|---|
| MCU | ATtiny841, I2C **slave at 0x08** on the Pi's bus |
| RTC | **PCF85063** at 0x51 on the MCU's *internal* bus |
| Temp | **LM75B** at 0x48 on the MCU's *internal* bus |
| Power in | **6-30 V** via XH2.54, *or* 5 V via USB-C — not "up to 30 V" |
| Output | up to 3 A to the Pi and its peripherals |
| Standby | **~0.5 mA** (manual) — the floor under any duty cycle |
| Telemetry | Vin, Vout, **Iout** — registers 1-6 |
| GPIO used | **4** (halt request), **17** (SYS_UP), **2/3** (I2C). **14/TXD monitored, not driven** |

**The 6 V minimum is a design constraint, not a footnote.** A single Li-ion
or LiFePO4 cell cannot feed VIN — the DC/DC will not start. Either your
battery is a 2S/3S pack, or the Pi is fed 5 V over USB-C from a separate
regulator and the Witty Pi's own converter goes unused. Your always-on rail
has to be sized against whichever you choose.

### Is the DC/DC bypassed on a USB-C feed?

It matters because a USB-C-fed board runs that way permanently, and because
the 6 V floor above is the converter's constraint — if the converter is out
of the path, the floor doesn't apply to a USB-C-powered board at all.

**VIN and 5V are two distinct nets.** The manual's interface list names them
separately, and there's an unpopulated power header carrying both — the
place to measure them without probing fine-pitch parts.

**The vendor describes USB-C mode as direct.** Register 7 (`POWER_MODE`)
reads *"Input 5V via USB Type C"* against *"Power via LDO regulator"*, and
the firmware comment is blunter: `0 if direclty use 5V input`.

**Nothing in software decides this.** The mode is derived by measurement —
`updateRegister(I2C_POWER_MODE, (vin > 5.25f) ? 1 : 0)` — and no register or
GPIO enables or disables the converter. Whatever bypassing happens is
analog, settled by which connector carries power.

To confirm on your own board: on USB-C with the XH2.54 empty, check whether
`Vout` exceeds `Vin` in `wittypi status` — a step-down converter cannot do
that, so if you see it, the 5 V rail is reaching Vout by some path other than
the buck converter (e.g. an ORing element), consistent with the converter
being out of circuit. Treat single-board ADC readings as approximate — the
divider has board-to-board tolerance and needs the `ADJ_VIN`/`ADJ_VOUT` trims
(see `WITTYPI-SETTINGS.md`) to be taken as calibrated numbers.

**What this doesn't change:** low-voltage protection is gated on
`POWER_MODE` in *firmware*, not on the analog path. Bypassed or not, USB-C
mode means registers 19 and 22 (`LOW_VOLTAGE`/`RECOVERY_VOLTAGE`) are
ignored — see §"Registers to set" below.

### Where the standby current actually goes

**On USB-C the Pi is the only thing switched off.** The AO4616 cuts the Pi's
5 V rail; the controller, RTC, temperature sensor and the sense dividers all
sit *upstream* of that switch and keep running from USB-C. The CR2032 is not
in this path — the manual is explicit that it is "for time keeping only,
when no power supply is connected", so with input power present it does
nothing.

Datasheet figures for the three named parts, against the manual's ~0.5 mA
board standby:

| | typical | max | conditions |
|---|---|---|---|
| PCF85063 RTC | **220 nA** | 450 nA | 3.3 V, 25 °C, interface inactive, CLKOUT off |
| | 470 nA | 600 nA | 85 °C |
| | 18 µA | 50 µA | interface active, fSCL 400 kHz |
| ATtiny841, power-down + WDT | **1.3 µA** | — | at 1.8 V (150 nA with the watchdog off) |
| ATtiny841, awake | **4.2 mA** | 6 mA | 8 MHz at 5 V |
| **LM75B** | **100 µA** | 200 µA | normal mode, bus idle. Shutdown mode would be 1.0 µA |

The MCU is not continuously awake: `sleep()` selects `SLEEP_MODE_PWR_DOWN`
and the watchdog fires **every second** (`WDTCSR |= 6`), so it wakes at
1 Hz, compares the alarm registers against the RTC, and drops back. Its
average draw is the power-down floor plus 4.2 mA times the awake fraction —
which is small but not zero.

**The RTC and the MCU are noise; the temperature sensor is not.** Those two
together are 2-40 µA of ~500 µA. **The LM75B alone is ~100 µA — roughly a
fifth of the whole standby budget — and the firmware never shuts it down.**
The only writes to it are the trip-point setup at init; temperature is read
by polling.

That still leaves most of the ~0.5 mA unattributed to datasheet figures:
regulator quiescent current, the ADC sense dividers (which draw
continuously), internal-bus pull-ups, the MOSFET gate circuit, and the buck
converter if it's biased rather than fully disabled on USB-C. An inline
meter on the input is the way to close that gap — datasheets alone can't.

**A shutdown trap worth naming explicitly:** register 51 exposes the LM75B's
own configuration register to the Pi, so userspace *can* set its shutdown
bit and claim back that ~100 µA. **Don't.** The firmware polls the
temperature register rather than using the LM75B's thermostat output, so a
shut-down sensor returns its last conversion forever — and over-temperature
protection would go on comparing against a frozen number while looking
perfectly healthy.

**Perspective before optimising any of this.** 0.5 mA at 5 V is 2.5 mW —
about 60 mWh/day. A Pi Zero W awake is ~0.6-0.75 W, so a few minutes of
awake time costs about as much as a full day of standby. The duty cycle is
where the battery goes, not the standby floor.

**The vendor manual is internally inconsistent on this figure** — the
specification table says ~0.5 mA standby, the dummy-load section elsewhere
says "Witty Pi 4 only draws about 1mA from the power bank." Measure your own
board rather than trusting either number: at the unpopulated power header,
with USB-C powered and the XH2.54 empty, measure VIN to GND (a value close
to the USB-C voltage confirms the two nets are tied through a drop); compare
`Iout` at the same load on USB-C against a VIN feed to see what the
converter costs when it's actually in circuit; or just feel the buck
converter IC under load — one doing work is warm.

**Don't feed both inputs at once.** Not for a documented failure — the
firmware handles a mode flip with 19/22 disabled correctly — but because the
ORing behaviour between the two nets isn't documented in the manual or
schematic.

### Powering or consoling over the Pi's own USB defeats the power switching

Two common bench conveniences both break the one thing this document is
about — the controller's ability to cut the rail.

**Power goes to the Witty Pi, never to the Pi.** The Witty Pi feeds the Pi
*through* the GPIO header, so a supply on either of the Pi's own USB ports
sits downstream of the switch and holds the board up after the controller
has cut it. 5 V into the Witty Pi's USB-C is a supported input; 5 V into the
Pi directly is not.

**A USB-gadget serial console is the same mistake wearing a disguise.** The
Pi Zero has no isolation between its OTG port's VBUS and the 5 V rail —
powering a Zero through its data port is a standard trick, and exactly the
problem here. Plug that port into a PC and the PC back-powers the board, so
the duty cycle silently never happens. The symptom is "the Witty Pi isn't
cutting power", and the cause is the console cable.

**So the console should be UART0 on the header**, reached with a USB-TTL
adapter, not a USB-gadget serial console.

**And that has its own interaction, which is not hypothetical.** The
controller decides the Pi has shut down by watching **TXD (GPIO-14) fall**.
The manual: *"if you connect some other devices that also use the TXD pin,
please make sure they don't change this default behavior, otherwise Witty Pi
4 doesn't know when the system is off, and cannot fully cut the power."* An
adapter whose RX input carries a pull-up to its own VCC can hold TXD high
while the Pi is off — and then the rail is never cut.

To check: with the Pi off and the adapter plugged into a PC, measure GPIO-14
to ground. It should not be held high. Leave the adapter's VCC disconnected
— ground, TX and RX only.

**Two mechanical facts worth knowing before the first bench session:**

- **A Pi Zero W ships with no 40-pin header.** The header must be soldered
  on before the Witty Pi can mount at all, unless the board is a Zero WH.
- **Never power the Pi directly while the Witty Pi is fitted.** A second
  supply on the Pi's own USB defeats the power switching and is how the
  controller loses the ability to cut the rail. Power goes to the Witty Pi,
  always.

**The RTC is a PCF85063, not a DS3231, and the temperature sensor is an
LM75B.** Both sit on an *internal* bus with the ATtiny as master, and the
MCU re-exposes them as *virtual* registers 50-71 to the Pi. Consequences:

- **Linux cannot bind a standard RTC driver, and there is no `/dev/rtc`.**
  No kernel config changes that — the parts aren't on a bus the kernel can
  see. Time is read and written through register access to 0x08 (registers
  54-71), which makes it userspace's job. A shim (`rtc-sync` style tooling)
  is required if you want the system clock set from the RTC at boot — see
  "The systemd units" below.
- The same is true of the temperature sensor: no `hwmon` driver will ever
  see the LM75B; register 50 is the only route to it.

**Registers 1-6 (Vin/Vout/Iout) are a real capability many similar boards
lack** — most power controllers in this class have no PMIC, no fuel gauge,
no current sense at all. Treat an uncalibrated `Iout` reading with
suspicion, though: values well below what your Pi model is known to draw at
idle usually mean the `ADJ_IOUT` trim hasn't been applied yet (see
`WITTYPI-SETTINGS.md`), not that the board is somehow drawing less power
than physically plausible.

---

## The three facts that shape everything

**1. Shutdown is requested on GPIO-4, and the Pi decides when to obey.** The
MCU pulls GPIO-4 low; a daemon on the Pi side sees it, runs any pre-shutdown
work, and only then calls `shutdown`. The vendor's own comment: *"Raspberry
Pi will not shutdown until all commands here are executed."*

**2. The rail is cut by watching TXD, not by a timer alone.**
`ISR (PCINT0_vect)` treats TXD going low, while `systemIsUp`, as the shutdown
signal — it sets `turningOff` and starts the power-cut timer
(`I2C_CONF_POWER_CUT_DELAY`, default 7 s on some firmware revisions). TXD
idles high only because UART is enabled for the console — the console and
the power sequencing depend on the same setting.

**3. There is also a timeout-based forced cut, independent of TXD.** The
timer ISR cuts the rail itself once the power-cut delay counts down from the
moment a shutdown was requested (a button press, an alarm, a low-voltage or
thermal trip):

```c
/* :772 — TIM1_OVF, once the power-cut delay has counted down */
if (powerCutDelay == 0) {
  TCNT1 = getPowerCutPreloadTimer(true);
  forcePowerCutIfNeeded();              // only fires on a held button
  if (turningOff) {
    if (turnOffFromTXD && digitalRead(PIN_TX_UP) == 1) { /* a reboot: keep the rail */ }
    else { cutPower(); sleep(); }       // where a scheduled/requested cut actually happens
  }
}
```

The countdown starts at the moment the shutdown was requested (a scheduled
alarm, the button, a low-voltage/thermal trip) — not at the TXD drop. So:
**the rail dies `POWER_CUT_DELAY` after the request, whether or not Linux
has finished shutting down.** This has two consequences, pointing opposite
ways:

- **A shutdown gate that hangs cannot strand the board indefinitely on the
  scheduled path.** The controller cuts the rail anyway, once the delay
  elapses.
- **If you're using a shutdown gate to protect an A/B update mechanism's
  boot-health check** (waiting for a soak period to complete before allowing
  a shutdown), **the gate's own timeout budget must fit inside
  `POWER_CUT_DELAY`, not inside your intended awake window.** A gate that
  assumes it can wait indefinitely for a health check to finish will instead
  be killed mid-wait when the rail is cut out from under it, and the record
  of what happened may never be written.

**And every shutdown reason goes through this same path.** Low voltage,
over/below temperature, and the schedule all request a graceful shutdown,
not an immediate cut. So a shutdown gate that hangs indefinitely doesn't
merely delay a scheduled sleep — on a battery topology it can defeat the
low-voltage protection while the battery keeps draining, since the graceful
path is the only one those triggers use.

---

## Design pattern: three layers of defence against "the board never wakes up again"

If you're building anything unattended on top of this controller, this
pattern is worth adopting directly — it's the reason a scheduling mistake or
a slow boot doesn't turn into a dead node.

### Layer 1 — size the awake window so your own health checks always complete

The only mechanism that's *supposed* to run; everything else is insurance.
If you're gating a health check (e.g. an A/B update mechanism's mark-good)
behind a soak period, your awake window needs to comfortably exceed:

```
T_boot       power-on -> your health check starts        (measure this)
T_soak       your health check's soak period              (measure this)
T_work       whatever the board is actually awake to do    ?
T_shutdown   your shutdown sequence -> TXD drops           (measure this)
POWER_CUT    TXD low -> rail off                           firmware default, register 21
```

A short, frequent duty cycle that looks efficient on paper can be shorter
than boot-plus-soak, in which case a health check *never* completes, its
own boot-attempt counter (if it has one) never resets, and after enough
cycles you can end up with a board that fails over — or fails outright —
for no fault of its own. If you're running an A/B update mechanism, do this
arithmetic before picking a cadence, not after.

### Layer 2 — a bounded shutdown gate

Insurance for the case where layer 1's arithmetic was wrong. If your
shutdown sequence needs to wait for something (a health check to finish, a
transfer to complete), bound that wait:

- **Don't gate urgent shutdown reasons at all.** Low voltage and thermal
  trips are the controller protecting the hardware; delaying them to tidy
  up application state is the wrong trade. Read `I2C_ACTION_REASON`
  (register 11) to tell which kind of shutdown this is.
- **Compute the deadline once, from a monotonic clock, before entering the
  wait loop.** Never re-derive it inside the loop or extend it based on
  anything observed while waiting — that's the standard shape of an
  unbounded-gate bug (a heartbeat that keeps proving "still working" can
  postpone the deadline indefinitely).
- **Time out and return, rather than block.** A missed health check costs
  one attempt out of however many your update mechanism budgets; a
  permanently held rail costs the whole battery, and on a solar node that's
  unrecoverable until the panel produces again. Log the timeout if you can;
  choosing the cheap failure and recording it is the right trade even
  without the log.

### Layer 3 — a guaranteed wake, so "off" is never permanent

`I2C_CONF_GUARANTEED_WAKE` (register 49): bits 0-6 a duration, bit 7 the
unit (0 = hours, 1 = days). The MCU wakes the board after that long
regardless of the schedule, and reports `REASON_GUARANTEED_WAKE` (12).

This covers the failure the other two can't: a corrupt or nonsensical
schedule that would otherwise leave the board asleep forever. A common
choice is 24-26 hours — far longer than any intended sleep, so it never
fires in normal operation, and short enough that a scheduling mistake costs
a day rather than the deployment. See `WITTYPI-SETTINGS.md` §4.1 for why
this layer is strongest on a USB-C/mode-0 topology and weaker on a battery
topology where its own voltage check can starve it.

---

## Coming back from a power loss — the one path, and why there is no second

**The three layers above do not cover this.** They protect a board that
*chose* to sleep. A board that lost input power is a different case, with
exactly one mechanism.

### Why the layers don't apply

When input power goes, **the MCU loses power too.** There's no counter
running, no alarm being matched, no state at all. When power returns,
`setup()` executes from scratch and reaches one branch:

```c
/* WittyPi4.ino:250-258 */
bool defaultOn = (i2cReg[I2C_CONF_DEFAULT_ON] == 1);
if (defaultOn) {
  delay(i2cReg[I2C_CONF_DEFAULT_ON_DELAY] * 1000);
  updateRegister(I2C_ACTION_REASON, REASON_POWER_CONNECTED);
  powerOn();
} else {
  sleep();          // <-- guaranteed wake AND the alarm checks live in HERE
}
```

`guaranteedWakeCounter` is incremented, and alarm housekeeping happens,
*inside* `sleep()`'s watchdog loop. So with `DEFAULT_ON = 1` the firmware
takes the *other* branch and never reaches `sleep()` at all — neither layer
3 nor the schedule can act, because neither is running.

| after… | routes back |
|---|---|
| a **requested** shutdown (alarm, button, thermal) | alarm1, the button, or guaranteed wake — the MCU reaches `sleep()` |
| **input power returning** | `DEFAULT_ON` alone. Nothing else exists |

### The `DEFAULT_ON_DELAY` overflow: a value above 32 can make this path unreachable

`int` is **16 bits** on AVR, so `reg * 1000` is evaluated *and wrapped*
before it's widened to `delay()`'s `unsigned long`. The widening happens at
the call boundary, after the damage:

| reg 47 | 16-bit result | `delay()` receives | |
|---|---|---|---|
| 32 | 32000 | 32 s | the largest that works |
| 33 | −32536 | ~49.7 days | first overflow |
| 66 | 464 | **0.46 s** | wraps *positive* — arbitrary, not merely long |
| 254 | −8144 | **~49.7 days** | a value that has actually caused a real outage |

Overflow begins at 33 (`33 × 1000 > 32767`). The vendor's own tool accepts
0-10 only. A board stuck on this path stays dark until input power returns
*again within the delay window* or someone presses the physical button —
guaranteed wake and alarm1 both live inside `sleep()`, the branch this path
never reaches.

### What guarantees the board returns

| | |
|---|---|
| register 17 (`DEFAULT_ON`) = 1 | should be asserted every boot by your configuration tooling |
| register 47 (`DEFAULT_ON_DELAY`) ≤ 32 | anything higher risks the overflow above |
| both live in the ATtiny's **EEPROM** | they survive the outage — the value that saves you is the one written *before* the outage, not anything Linux does afterwards |

### Two hazards specific to a brownout rather than a clean power loss

**1. AVR brown-out detection is a fuse setting, external to this firmware
source.** A clean collapse resets the MCU cleanly. A slow sag into the grey
zone can leave an AVR hung rather than reset unless the BOD fuse is enabled
— check your board's fuse settings if you're reflashing, since a marginal
supply could otherwise hang the MCU before `setup()` runs, and no register
value helps at that point. Testing this needs a variable bench supply;
yanking a plug only tests the clean case.

**2. Repeated brief power cycles (chatter) can burn through an A/B update
mechanism's boot-attempt budget**, if you're using one — each power-on
typically counts as an attempt, and a mechanism's own "mark healthy" step
usually needs the board to stay up past its own soak period first. A charger
board's low-voltage-disconnect hysteresis is usually the only thing standing
between a marginal supply and burning through that budget — size it with
that in mind (see `WITTYPI-SETTINGS.md` §4.1), not just the battery.

---

### The default-on delay is not a quiet wait — everything is live during it

Register 47 is used in exactly **one** place and it's easy to picture the
board sitting inert. It's not. In `setup()`, by the time the delay runs, the
I2C slave is already up, pin-change interrupts are armed, the watchdog is
enabled, and the 1 Hz ISR is running every handler — only the Pi's own rail
is down and `powerIsOn == false`. `powerOn()` has not run yet.

**What that does NOT cost you.** `powerOn()` is what zeroes the
temperature/low-voltage inhibit counters and the guaranteed-wake counter,
and it runs *after* the delay — so the delay doesn't eat into those inhibit
windows. The delay is invisible to all three.

**What register 47 actually interacts with:**

| Register | Interaction |
|---|---|
| **17** `DEFAULT_ON` | Gates it. The delay applies **only** to power-return — never to an alarm1 wake and never to a button press |
| **11** `ACTION_REASON` | Set to `REASON_POWER_CONNECTED` (10) *after* the delay, unconditionally overwriting whatever the ISR wrote during it |
| **27-31, 9, 39** alarm1 | If alarm1's 2 s window lands inside the delay: flags set, `REASON_ALARM1` written, and because `!powerIsOn`, `powerOn()` runs from the ISR mid-delay. The rail comes up early, then the delay ends, `powerOn()` runs again, and the reason is overwritten to 10. Register 39 is the only surviving evidence it was alarm1 |
| **32-36, 10, 40** alarm2 | The appointment is consumed and discarded — see below |
| **7, 19, 22** power mode / voltages | Via `canTriggerAlarm()`. On USB-C (mode 0) it returns true immediately, so alarms always fire. On a battery topology with input below `LOW_VOLTAGE` it returns false and suppresses alarm triggering entirely |
| **48** `MISC` bit 0 | Alarm1-delayed retry — requires `powerIsOn`, so unreachable during the delay |
| **21** `POWER_CUT_DELAY` | Indirect: the button path reloads the power-cut timer |

#### An alarm2 that elapses with the rail down is consumed, not deferred

`processAlarmIfNeeded()` sets `ALARM2_TRIGGERED` and `FLAG_ALARM2`
**before** it checks whether anything should happen:

```c
} else if (canTrigger && !alarm2HasTriggered && overdue_alarm2 >= 0 && overdue_alarm2 < 2) {
  updateRegister(I2C_ALARM2_TRIGGERED, 1);      // <- unconditional
  updateRegister(I2C_CONF_FLAG_ALARM2, 1);      // <- unconditional
  if (powerIsOn && !turningOff) {               // <- the action is gated
```

While the rail is down, `powerIsOn` is false, so the flags are set and no
shutdown happens — the appointment is spent. Harmless in the ordinary case
(the board is already off, which is what alarm2 wanted). It is **not**
harmless during the default-on delay: power returns, the delay begins,
alarm2's instant passes inside it, the shutdown that was meant to bound this
awake window is marked triggered, and the board then powers on with no
scheduled shutdown at all — it stays awake until guaranteed wake is the only
thing left. This is an argument for keeping `DEFAULT_ON_DELAY` short: every
second of it is a second in which a scheduled shutdown can be silently
swallowed.

---

## The alarm is not a schedule — it is a single appointment

Registers 27-31 (alarm1, startup) and 32-36 (alarm2, shutdown) each hold
**one absolute moment**, as day-of-month/hour/minute/second in BCD. The
firmware doesn't pattern-match them against the clock; it converts both to a
number and compares:

```c
/* WittyPi4.ino:1027 */
long getTimestamp(byte date, byte hours, byte minutes, byte seconds) {
  return (long)date * 86400 + (long)hours * 3600 + (long)minutes * 60 + seconds;
}
/* :878 — the whole trigger condition */
if (canTrigger && !alarm1HasTriggered && overdue_alarm1 >= 0 && overdue_alarm1 < 2)
```

Three consequences, all load-bearing:

- **An alarm fires exactly once.** The latch clears only on a write to
  registers 27-31. A schedule written once at commissioning runs for one
  cycle and then the board sleeps forever unless something rewrites it.
- **There are no wildcards, and the day cannot be made one.**
  `getTimestamp()` folds the day *into the value being compared*, so there's
  no bit that could mean "any" — a wildcard isn't a flag the firmware
  declines to read, it's a shape the comparison cannot express. The
  PCF85063's own alarm registers do support "don't care" bits, and the
  firmware does mirror bytes into them, but it never reads the RTC's own
  alarm flag to decide anything — the timestamp comparison is the whole
  decision.
- **The trigger window is 2 seconds wide.** Miss it and the alarm doesn't
  fire late; it doesn't fire at all. The watchdog ISR evaluates it once a
  second, so the margin is one tick.

**So the schedule is a promise your software renews on every wake.** The
ordering of that renewal is the whole game:

```
 1. sync the system clock from the RTC        # there is no /dev/rtc; nothing else does this
 2. WRITE ALARM1 — the next wake                ← FIRST. Always first.
 3. write ALARM2 — the end of this window
 4. do the work
```

**Alarm1 is written before anything else can fail.** If the board dies at
any point after step 2 — a panic, a bad update, a hung service, an
over-temperature cut — it still wakes at the next appointment. Reverse the
order and a crash between the two writes leaves a board that has scheduled
its own shutdown and nothing to bring it back.

Day-of-month arithmetic is the one fiddly part: the next wake may be
tomorrow, and tomorrow may be the 1st. Both sides of the comparison use
day-of-month, so month rollover is handled correctly *provided your
scheduler computes the real next day-of-month* — which needs month length
and leap years. A sleep longer than about 28 days cannot be expressed at
all.

### Making the scheduler a pure function of the clock

**The asymmetry to design around: several mechanisms push the board *up***
(alarm1's deferred re-fire, a supervisor's backstop, guaranteed wake), **but
nothing pushes it *down*.** There's no "guaranteed shutdown" — any state
where alarm2 is missing or spent has no automatic exit, and a board that
stays awake flattens the pack. That's the expensive direction, and it's also
the hardest to repair if your scheduler isn't idempotent: if arming alarm2
means "wake in N seconds from right now", running the arming logic twice
pushes the shutdown out twice, which means it can only safely run once per
boot — and the only thing that would re-run it is a boot, which is exactly
what a stuck-awake board doesn't get.

**Phase anchoring breaks that loop.** Make cycle boundaries absolute —
multiples of `CYCLE = ON + OFF` since some epoch — so the alarm pair becomes
a pure function of (clock, ON, OFF):

```
stop = <start of the current window> + ON      (≡ ON mod CYCLE)
wake = stop + OFF                              (≡ 0  mod CYCLE)
```

Apply two floors and take the **later** of them, so the result can't
mis-fire at either end: the stop time must clear *now* by some lead margin
(an appointment in the past cannot fire — the match window is 2 s and the
firmware doesn't fire late), and it must clear your own health-check soak
plus margin. If either floor isn't met, advance by whole cycles rather than
computing a short one. Sleep is then always exactly `OFF`.

This gives you three properties that matter downstream: **idempotent** (a
re-run mid-window rewrites the same two values, so it's safe to call from a
watchdog/repair process as well as at boot), **predictable** (the awake
window lands at the same wall-clock offsets every cycle), and **drift-free**
(boot latency doesn't walk the schedule forward a little each cycle).

**And that's what makes a repair process safe to add.** A supervisor that
notices the schedule looks wrong can just re-run the same idempotent
arming logic rather than needing its own separate "fix it" code path — as
long as the thing doing the writing really is a pure function of the clock,
not something that reads its own prior output as an input.

#### An absent controller means different things, and your config should say which

Checking for the controller (e.g. reading its firmware-ID register) returns
false for two situations it cannot tell apart: **no controller fitted** — a
bench Pi, a supported configuration — and **a controller that didn't answer
this particular read**, which a busy bus, a cold MCU, or a marginal rail can
all produce. Don't let "no controller detected" silently mean "nothing to
do" if you have config elsewhere declaring that a controller *should* be
present — a board that's opted into a duty cycle but gets a false negative
on the controller probe can end up with nothing arming its wake and nothing
noticing. Probe repeatedly before declaring the controller absent, and treat
"opted in but still unresponsive" as a hazard to alert on, not a quiet no-op.

#### "The scheduled shutdown time is in the past" is two states with opposite severities

They can have identical registers:

| | what it means | severity |
|---|---|---|
| the board was **off** while the appointment elapsed | a stale leftover from before the board lost power — the MCU loses power on an unplug, but the coin-cell-backed RTC does not, so the alarm block keeps whatever it last held while the clock keeps running. Re-plug days later and the alarm reads "days in the past" | benign — nothing was drained, the boot-time scheduler owns rearming it |
| the board was **awake** and blew through it | the scheduled shutdown didn't happen, and nothing in the firmware stops a board that stays up | expensive — this is the battery |

Uptime distinguishes them: a board up for less time than the appointment is
overdue by cannot have been awake when the moment passed. If you're building
a watchdog around this, check uptime before deciding whether a stale alarm
is a page-worthy event or a normal boot-time cleanup.

### An alarm1 that fires while the board is awake poisons the *next* sleep

The firmware explains this exactly:

```c
if (canTrigger && !alarm1HasTriggered && overdue_alarm1 >= 0 && overdue_alarm1 < 2) {
  if (!powerIsOn) {
    updateRegister(I2C_ACTION_REASON, REASON_ALARM1);
    emulateButtonClick();                       // the normal wake
  } else {
    // power is not cut yet, will power on later if alarm1 delay is allowed
    if ((i2cReg[I2C_CONF_MISC] & 0x01) == 0) { alarm1Delayed = 1; }
  }
}
```

and, in the 1 Hz tick:

```c
if (!powerIsOn && alarm1Delayed > 0) {
  alarm1Delayed++;
  if (alarm1Delayed == 4) { alarm1Delayed = 0;
                            updateRegister(I2C_ACTION_REASON, REASON_ALARM1_DELAYED);
                            emulateButtonClick(); }
}
```

So: **if alarm1 ever comes due while the rail is still up, the MCU doesn't
discard it — it remembers, and powers the board back on 4 ticks after the
next power-off**, whenever that happens to be. The OFF window is silently
short-circuited. Three properties worth knowing before this is met live:

- **The memory is in MCU RAM, which the rail cut doesn't clear** — the ATtiny
  is always powered, so the poisoning survives the very power-off it
  corrupts, and there's no register exposing `alarm1Delayed` to the Pi. The
  only visible trace is reason **8** (`REASON_ALARM1_DELAYED`) on the
  following boot.
- **It's a one-shot** — the flag resets to 0 when it fires, so exactly one
  sleep is lost and the cycle recovers by itself. A single reason-8 boot
  isn't worth chasing; a *repeating* one is.
- **Don't "fix" it by setting bit 0 of register 48** (`MISC`). That bit
  doesn't prevent the alarm being consumed while awake — it only stops the
  MCU compensating. The board would then power off having already spent its
  wake, and the next thing to bring it back would be guaranteed wake, up to
  a day later. The default behaviour is a deliberate safety net: an
  unplanned early wake is a better trade than a possible day of darkness on
  an unattended node.

The real lesson is upstream: the board must not still be awake when alarm1
comes due — that's what a well-designed scheduler's bounds should enforce,
and why alarm2 (shutdown) should always be set well inside alarm1 (next
wake).

---

## Registers to set — and the two power topologies

Three registers and one behaviour differ depending on how you power the
board; everything else — the schedule renewal, a bounded shutdown gate, the
LED, temperature actions, guaranteed wake's existence — is identical either
way.

| | **A — 5 V into USB-C** | **B — 2S battery on VIN** | **C — 3S battery on VIN** |
|---|---|---|---|
| `POWER_MODE` reads | **0** | 1 | 1 |
| Low-voltage shutdown | **inert** | works | works |
| Scheduled wake gated on voltage | no — always wakes | yes | yes |
| Guaranteed wake (layer 3) | **unconditional** | gated on recovery voltage | gated on recovery voltage |
| Cell balancing | none needed (single cell, or upstream regulator) | needs a **balancing BMS** | needs a **balancing BMS** |
| Headroom over the 6 V floor | n/a | thin — measure the dropout first | comfortable |
| Verdict | simplest; pack supervision lives off-board | margin-free on a nominal 2S pack | the one to choose if leaving USB-C |

### Topology A — 5 V into USB-C

> #### The 5 V feed disables low-voltage protection
>
> `updatePowerMode()` sets `I2C_POWER_MODE = (vin > 5.25f) ? 1 : 0`, so a
> USB-C supply reads mode 0. Every voltage-aware behaviour is gated on mode
> 1:
>
> | Behaviour | Gate | In mode 0 |
> |---|---|---|
> | low-voltage shutdown | `POWER_MODE == 1 \|\| IGNORE_POWER_MODE == 1` | **never fires** |
> | wake suppressed on a flat battery | `canTriggerAlarm()` returns true at once | **always wakes** |
> | guaranteed wake's voltage check | skipped entirely | **always wakes** |
>
> Register 41 (`IGNORE_POWER_MODE`) would force the logic back on, and it
> shouldn't be used here, because the ADC is on the wrong side of any
> upstream regulator — it measures VIN, the regulator's *output*, not the
> pack. A regulator holds 5 V flat while its input sags across most of a
> discharge curve, so the measured number carries no state-of-charge
> information and then collapses suddenly at the end. Worse, a regulated
> rail recovers the instant the load is shed, so a threshold on it
> oscillates: shutdown → rail springs back → recovery wake → boot → sag.
>
> **There's no wiring that fixes this.** VIN needs 6-30 V; a single cell is
> 3.0-4.2 V and won't start the DC/DC. Anything that boosts it to 6 V+ hides
> the battery from the same ADC.
>
> **So battery protection isn't this board's job on this topology.** It has
> to live where the pack is actually visible: an autonomous low-voltage
> disconnect on the charger/regulator board itself (which also needs to
> cover any always-on loads that keep draining after the Witty Pi cuts the
> Pi's rail), and/or reading real pack voltage from some other peripheral
> that has its own ADC, if one is already on the bus for another reason.

### Topologies B and C — a pack on VIN

Feeding the XH2.54 connector puts the board in mode 1 and every gate in the
table above flips on. The vendor states the dependency plainly — both
thresholds apply "if you are powering your Witty Pi via the XH2.54
connector", settable 2.0-25.0 V.

Two inversions decide the numbers, and neither is obvious.

**1. "Guaranteed" wake stops being guaranteed.**

```c
/* WittyPi4.ino:363-372 */
if (i2cReg[I2C_POWER_MODE] == 0) {
  guaranteedWake = true;                  // USB-C: unconditional
} else {
  if (vin >= vrec) guaranteedWake = true;
  else guaranteedWakeCounter = 0;         // ← not a retry. A full restart.
}
```

On VIN, layer 3 fires only above the **recovery** voltage, and a failed
check doesn't retry shortly — it zeroes the counter, postponing by another
entire period. Set `RECOVERY_VOLTAGE` near the pack's float voltage and the
last-ditch defence can be starved for a long time, precisely when it's the
only thing left. **So recovery voltage must be set low** — high enough to be
real hysteresis, low enough not to gate the safety net. That inverts the
instinct to put it near a full charge.

Note the asymmetry: **layer 3 is strongest on topology A**, the topology
with no battery protection at all. The two facts partly offset.

**2. A scheduled wake landing in a brownout is lost, not deferred.**
`canTriggerAlarm()` returns false below the low-voltage threshold, and the
trigger window is two seconds wide — so the alarm doesn't fire late, it
doesn't fire. What brings the board back is a separate recovery path that
arms a voltage-restore wake, returning **when the battery recovers, at an
arbitrary time of day** — often the next morning for a solar-charged pack,
which is the right answer reached sideways.

The consequence for your schedule renewal logic: **compute the next window
from the clock, never from an assumption about when this particular wake
happened.** Code that assumes it woke at 09:00 because that's what it asked
for will write the next alarm wrong after every voltage-recovery wake.

**Thresholds**, per cell and in the register's x10 encoding:

| | 2S | 3S |
|---|---|---|
| Full / nominal | 8.4 V / 7.4 V | 12.6 V / 11.1 V |
| `LOW_VOLTAGE` (19) | 6.6 V → `66` (3.3 V/cell) | 9.6 V → `96` (3.2 V/cell) |
| `RECOVERY_VOLTAGE` (22) | 7.0 V → `70` | 10.2 V → `102` |

> #### 2S may have no real margin, depending on your converter's UVLO
>
> The MP4462 (the buck converter this board uses) is specified to 3.8 V
> input with a 3.0 V UVLO by its own datasheet, so the board's stated 6 V
> minimum is a margin UUGear chose on top of that, most plausibly via the
> EN-pin divider. The datasheet's own application note recommends
> programming that input UVLO to output-plus-3V, which for a 5 V output is
> 8 V — if the board followed that note, a 2S pack could drop out at 8.4 V,
> i.e. almost immediately.
>
> **Measure it before committing to a 2S pack.** Bench supply into the
> XH2.54, Pi running, wind the input down and record where Vout collapses.
> One measurement decides whether a 2S topology is viable at all for your
> board.

3S carries none of that risk. **If you're leaving USB-C, prefer 3S over
2S.**

**What a VIN topology costs, and it's not nothing:** any load that needs to
stay always-on (radios, sensors) can no longer run straight off the pack at
9-12.6 V without their own always-on buck converter, whose quiescent current
is paid 24 hours a day. And a series pack needs a **balancing** BMS, where a
single large parallel cell (or bank of them) self-balances by construction —
cell divergence in a series pack is a real failure mode over a couple of
years that a single-cell/USB-C topology simply doesn't have.

### The register table

Rows marked A/B/C are the only ones the topology changes.

| Reg | Name | Value | Why |
|---|---|---|---|
| 17 | `DEFAULT_ON` | **1** | After a power interruption the board must come back without a human. |
| 47 | `DEFAULT_ON_DELAY` | **≤ 32** | `delay(reg * 1000)` is computed in a 16-bit int, so anything ≥33 wraps to ~49.7 days (see above). The vendor's own tool accepts 0-10. |
| 20 | `BLINK_LED` | **0** | The white LED blinks 100 ms every few seconds **while asleep** — a meaningful fraction of a ~0.5 mA standby budget if the board sleeps most of the day, and a visible beacon if that's undesirable. |
| 23 | `DUMMY_LOAD` | **0**, usually | Not a resistor — it re-asserts the Pi's own 5 V rail for N ms and then cuts power again. Exists because a USB power bank auto-shuts-off below some minimum current draw, and idle Witty Pi standby is nowhere near that, so the bank sleeps and a scheduled wake never lands. Only useful if your field supply is genuinely a power bank rather than a charge controller — otherwise it's pure loss, and at high values it can begin a boot and cut it mid-start, repeatedly. |
| 21 | `POWER_CUT_DELAY` | site-specific, see `WITTYPI-SETTINGS.md` | x10 seconds. Needs to comfortably exceed your shutdown sequence's actual duration. |
| 19 | `LOW_VOLTAGE` | **A: 255** (disabled) · **B: 66** (6.6 V) · **C: 96** (9.6 V) | On A it's inert, and disabled deliberately rather than left at a number that looks like protection. On B/C it's the protection. |
| 22 | `RECOVERY_VOLTAGE` | **A: 255** · **B: 70** (7.0 V) · **C: 102** (10.2 V) | Must exceed 19, or the board oscillates — and must stay **low**, or it starves guaranteed wake. Never set without also setting 19: alone, it arms a recovery wake that fights the schedule. |
| 41 | `IGNORE_POWER_MODE` | **0** on every topology | On A it would force a useless LVD onto a regulated rail; on B/C the board is already in mode 1 and doesn't need it. |
| 45/46 | `OVER_TEMP_ACTION` / `_POINT` | **1** / site-specific | Protects the board, not the pack — the LM75B is on the controller. |
| 43/44 | `BELOW_TEMP_ACTION` / `_POINT` | **0** / — | Cold usually isn't a reason to stop, and this isn't the battery's temperature — charging below freezing is the charger board's own interlock, if it has one. |
| 49 | `GUARANTEED_WAKE` | site-specific, exceed your longest intended sleep | See layer 3 above. |
| 48 | `MISC` | **0** | Keep alarm1-delayed retry enabled — see the poisoned-sleep section above. |
| 24/26 | `ADJ_VIN` / `ADJ_IOUT` | calibrate | Both default to a non-zero trim, which is the vendor saying these need it per board — see `WITTYPI-SETTINGS.md`. |

> #### 255 in a register doesn't always mean 255 — it can mean "never written"
>
> `initializeRegisters()` synchronises the register file with EEPROM on
> every MCU start, and it reads a stored 255 as an unwritten cell:
>
> ```c
> byte val = EEPROM.read(i);
> if (val == 255) EEPROM.update(i, i2cReg[i]);   // <- a written 255 is discarded
> else            i2cReg[i] = val;
> ```
>
> So **any register whose intended value is 255 holds it only until the MCU
> next loses power.** For `LOW_VOLTAGE` and `RECOVERY_VOLTAGE` this is
> harmless — 255 is also their compiled default, so the rewrite is a no-op.
> For `DEFAULT_ON_DELAY` it is not: the compiled default there is 0, not
> 255. A delay of 255 would survive until the first power loss and then
> vanish — on precisely the event it exists to soften. This is why the
> maximum sane value for that register is 32 (the arithmetic limit) and why
> tooling should refuse 255 for it specifically rather than treating it as
> "maximum caution."

**Fit the CR2032.** The RTC draws ~0.22 µA from it. Without it, a full pack
collapse resets the clock to 2000-01-01, and a stored alarm ends up roughly
13 days in the RTC's future — the board stays dark until guaranteed wake
fires. The board also has an unpopulated 2-pin header wired straight to the
CR2032 holder's two poles, meant for attaching an external charger if you
choose to fit a rechargeable cell instead — as shipped (unpopulated, no
onboard charge circuit wired to it), there's nothing to disable if you use a
standard non-rechargeable CR2032.

A dead cell reproduces a very specific symptom: the clock reads
2000-01-01, distinguishable from a genuinely stuck clock, and any RTC-sync
tooling should refuse to trust it or to overwrite it with a
pre-build-epoch system clock.

Two smaller things the firmware settles, worth not re-deriving:

- **Guaranteed wake doesn't use the RTC.** It counts watchdog ticks and is
  reset by `powerOn()`. So layer 3 still fires on a board whose clock has
  been lost — exactly the case where a schedule is useless, and the reason
  a missing CR2032 is survivable rather than fatal.
- **The schedule survives an RTC power loss, but the time doesn't.** Alarms
  live in the MCU's EEPROM-backed registers, not in the RTC itself, so a
  flat coin cell loses the *time*, not the *schedule* — which is exactly
  why a lost clock can turn a correct schedule into an alarm that reads as
  "13 days in the future."

### If you're gating an update mechanism's health check behind the awake window

The pattern in "Design pattern" above has one more sharp edge worth naming:
a shutdown gate that only checks "is the *currently running* slot/version
healthy" knows nothing about an update in progress into an *inactive* slot.
If a scheduled shutdown fires mid-install, the gate sees the running slot
already fine and returns immediately, and the board powers off mid-install —
every individual cycle looks healthy, but the update never completes. This
is a livelock, not a single failure, so it can hide indefinitely. Either
teach the gate about an install in progress (and give that its own bound,
for the same reasons as any other gate here), or run installs under a
separate, deliberately longer window rather than trying to fit them into a
routine duty cycle.

### Sizing the duty cycle

Two relationships need to hold, whatever cycle you pick:

| bound | why |
|---|---|
| `ON ≥ T_health_soak + margin` | An ON window shorter than your health-check soak means every scheduled shutdown lands before anything gets marked healthy — see "Design pattern" layer 1. |
| `ON + OFF ≤ guaranteed_wake − margin` | Guaranteed wake is the last-resort backstop. A cycle that outruns it turns a missed alarm1 from "late by the remainder" into "dark until someone visits." Leave an hour or so of margin rather than racing alarm1 exactly. |

For a solar-powered deployment, a single daily window timed to charging
hours is often the easiest way to satisfy both comfortably — a 2-3 hour
morning window, for instance, leaves boot-plus-soak with plenty of headroom
and puts `ON + OFF` well under a 24-26 h guaranteed wake.

Put the window in the **morning, not solar noon**, if daylight matters: the
panel is already producing, so the board's awake-hour draw comes off the
panel instead of costing a battery charge/discharge round trip, and an
enclosure's thermal peak typically lags the sun by a couple of hours, so a
morning window stays clear of both an over-temperature trip and the hottest
part of the day for the cells.

**The two-year risk for an outdoor Li-ion deployment is usually calendar
aging, not the power budget.** Cells held near full charge at high
temperature in a sealed enclosure can lose significant capacity in a single
hot season, and no controller register affects that. Shade or vent the
enclosure, keep the pack away from the electronics' own heat, and if your
charger's float voltage is adjustable, lowering it slightly (e.g. from 4.20
to 4.05-4.10 V/cell) roughly doubles calendar life for a small capacity
cost.

---

## Reflashing the controller — read this before you do

"Recompile it with different settings" doesn't mean what it sounds like on
this firmware.

### EEPROM wins. Changing a compiled default usually changes nothing

`initializeRegisters()` sets a handful of defaults and then does this:

```c
for (byte i = 0; i < I2C_REG_COUNT; i ++) {
  byte val = EEPROM.read(i);
  if (val == 255) { EEPROM.update(i, i2cReg[i]); }   // unset -> seed from firmware
  else            { i2cReg[i] = val;             }   // set   -> EEPROM WINS
}
```

**Every byte in EEPROM that isn't 255 overrides the firmware's compiled
default.** On any board that's ever been configured — which is any board
your own configuration tooling has touched, if it runs every boot — that's
nearly all of them.

So if you recompile with different values in `initializeRegisters()` and
flash it while preserving EEPROM, **your new settings are silently
ignored.** The board keeps behaving exactly as before and nothing reports a
problem.

### Which knobs belong where

| Want to change | Where it belongs |
|---|---|
| Anything the register policy writes — power-cut delay, default-on (+delay), temperature points/actions, guaranteed wake, LED, dummy load, voltage thresholds | Your own site config, applied every boot by your configuration tooling. Version-controlled, sanity-checked, survives a reflash. |
| Register **18** (sleep pulse interval) | Firmware, or a manual one-off `wittypi set 18` — this is one config register most policies don't write, so it's the one where a compiled-default change actually reaches a wiped board. |
| The **2 s alarm window**, the **thermal/low-voltage post-boot inhibit periods**, the **1 Hz tick**, the `delay(reg * 1000)` overflow above 32, the alarm1-delayed retry cadence | Firmware only. No register controls these. |

The last row is the real reason to recompile at all — everything else is a
config change wearing a firmware costume.

### If the flash erases EEPROM, the board comes up dark

**Register 17 (`DEFAULT_ON`) has no compiled default at all** — it's a
plain global that zero-initialises. A wiped EEPROM therefore means
`defaultOn == false`, `setup()` calls `sleep()`, and the board waits for a
button press — exactly the failure "Coming back from a power loss" above
exists to eliminate.

And the seeded `POWER_CUT_DELAY` on a wiped board is 7.0 s, likely below
what your shutdown sequence actually needs — a wiped board could cut the
rail mid-shutdown until your policy is reapplied.

Both self-heal *once the board boots*, if your configuration tooling runs at
every boot. The gap is getting it to boot: press the physical button once
after a flash that erased EEPROM, then confirm the policy landed. Preserving
EEPROM (the `EESAVE` fuse, or an `avrdude` invocation that doesn't
chip-erase) avoids the gap entirely.

### There is no integrity check anywhere on this firmware

Checked by reading the source, not assumed: nothing matching
`crc|checksum|magic|signature|validate` appears anywhere in it. The EEPROM
is a flat 1:1 shadow of the registers with no header, no version, no magic
byte, and no length. The load logic is the eleven lines quoted above, and
that's the entire mechanism.

So, precisely:

| | |
|---|---|
| A corrupted EEPROM byte | is adopted verbatim, as policy. Nothing range-checks it. 255 is the *only* value with meaning ("unset") — every other value is believed. |
| Corrupted program flash | nothing checks it. No CRC, no bootloader verification. |
| A hung MCU | is not reset by its own watchdog. The watchdog here is configured as a 1 Hz timebase interrupt, not a reset source — a hung controller stays hung with the rail wherever it was. |

For an unattended deployment, design around this: safer compiled defaults
don't help, because they're only consulted when a byte reads exactly 255. A
byte corrupted to 3 isn't a byte that falls back — it's whatever a literal 3
means for that register (e.g. a very short power-cut delay). The registers
where that matters most are `POWER_CUT_DELAY` (a cut mid-write),
`DEFAULT_ON_DELAY` (the 16-bit overflow above 32) and `DEFAULT_ON` (dark
until someone presses the button).

### The firmware revision lives inside the same EEPROM shadow, so bumping it isn't enough on its own

`I2C_FW_REVISION` (register 12) is inside the EEPROM-backed range like
everything else. On any board that's run before, EEPROM byte 12 already
holds the old revision number, the load loop sees a value that isn't 255,
and **the old revision overwrites the new one.** Flash a new revision onto a
previously-configured board and the revision register still reads the old
value.

It also can't be corrected from Linux: I2C writes are only accepted for
register indices at or above the configuration range, so a userspace
"set the revision register" call is refused by the firmware. The revision
only changes if that EEPROM byte is erased at flash time — so if you're
shipping a firmware update, decide (and record) whether you erased EEPROM,
since anything checking the revision register depends on it.

### Live measurements written to EEPROM, every second, on a VIN topology

`updateRegister()` writes EEPROM for **every** register index below the
config range — including registers 1-6, the live ADC readings for input
voltage, output voltage and output current.

That's dormant on a USB-C topology (the low-voltage path returns early when
`POWER_MODE` is 0), but live on a VIN/battery topology: the low-voltage
check runs from the 1 Hz watchdog ISR, and while `EEPROM.update()` skips
unchanged bytes, the fractional-volt byte moves most seconds from ADC noise
alone.

At the ATtiny841 datasheet figure of 100,000 EEPROM write/erase cycles, one
write per awake second is roughly 28 hours of continuous uptime, or on the
order of 100 days at a short daily window, before that byte's write budget
is exhausted. Not an immediate problem for a short duty cycle, but worth
knowing if you're moving toward a topology or a schedule where the board is
awake on VIN power for long, continuous stretches. Don't try to work around
it by polling voltage from Linux instead — every read of those registers
over I2C triggers the same ADC-plus-EEPROM write path, so a monitoring loop
costs exactly what the VIN-side firmware path costs.

### If you're recompiling anyway, worth doing in this order

1. **Stop persisting registers that should never have been persistent.**
   Registers 0-7 and 12 are identity and live measurements — meaningless
   across a power cycle and the entire source of the EEPROM wear above.
   Keep 8-11 persistent: `ACTION_REASON` surviving the rail cut is what
   lets anything answer "why did I wake."
2. **Validate on load.** A magic byte plus a version, checked before the
   EEPROM shadow is trusted; on mismatch, ignore it and re-seed from the
   firmware. This is the only change that turns "corrupted" into
   "recovered" rather than "silently adopted."
3. **Range-check the config registers** as they're loaded, falling back to
   the firmware value on an out-of-range read — at minimum
   `DEFAULT_ON_DELAY <= 32` (the overflow) and `DEFAULT_ON` in `{0,1}`.
4. **Safe compiled seeds** that only matter on a wiped EEPROM but cost
   nothing: `DEFAULT_ON = 1` (come back without a button) and a
   `POWER_CUT_DELAY` that matches your actual shutdown budget rather than
   the vendor's 7.0 s default.

Each of these is a firmware change with no register equivalent — that's the
test for whether something belongs in a recompile at all, versus in your
site configuration.

---

## The systemd units — a reference shape

If you're integrating this controller on an image where the vendor's own
Bash tooling doesn't fit (a read-only rootfs, a non-Raspberry-Pi-OS
distribution, a security-hardened image), this is the shape that works:

```
data.mount
   │
   ├─ wittypi-configure.service   oneshot   assert the register policy
   │
   ├─ wittypi-clock.service       oneshot   sync system clock from the RTC
   │
   ├─ wittypi-schedule.service    oneshot   write alarm1, then alarm2
   │
   └─ wittypi.service             simple    signal boot, wait, gate, power off
          │
          └─ your own work: ordinary units, After=wittypi.service
```

**A clock-sync unit is easy to forget, and its absence isn't obvious.**
There's no `/dev/rtc` on this controller — the RTC is proxied behind
register access, so no kernel driver can bind and systemd has nothing to
read at boot. The only path from the RTC to the system clock is an explicit
sync command, and if nothing invokes it, every boot starts with whatever the
kernel guessed. Order the clock-sync unit *before* the schedule-writing
unit, or a naive port of vendor scheduling logic that waits for a sane clock
can spin forever.

**The schedule-writing unit replaces the vendor's `.wpi`-file interpreter.**
What that interpreter does, though, isn't optional: it must recompute alarms
every boot, because the alarm registers hold one appointment that fires
once — see "The alarm is not a schedule" above. Its ordering matters more
than its implementation: **alarm1 first**, so a crash at any later point
still leaves a board that wakes at the next appointment.

> **A systemd subtlety worth knowing:** ordering a unit after the
> boot-signal unit guarantees only that the *process started*, not that the
> handshake with the MCU completed — if that handshake takes a few seconds
> to settle, a schedule-writing unit ordered immediately after it can still
> race it. The window is usually short and both failure modes are
> survivable (no alarm1 written yet → guaranteed wake recovers eventually;
> handshake not yet complete → the rail isn't cut, which just delays sleep),
> so letting the handshake go first is a reasonable default. If strict
> sequencing matters more to you, use `Type=notify` and an explicit
> readiness notification after the handshake completes, not a fixed sleep in
> a unit file.

### Porting notes, if you're replacing the vendor's Bash tooling

The vendor's `Software/wittypi/utilities.sh` (nearly 700 lines) assumes
Raspberry Pi OS throughout — it calls the deprecated `wiringPi` `gpio` tool
at two dozen call sites, relies on GNU `date` semantics at dozens more
(where a busybox/ash environment differs), rewrites `/boot/config.txt` on
what may be a read-only rootfs, and greps `/etc/os-release` to decide which
Raspberry Pi OS release it's on. None of that ports cleanly to a general
Linux/systemd image, which is the reason this repo's `wittypi-lib.sh`
exists as an independent implementation rather than a port.

If you're doing the same replacement, `libgpiod` covers every `gpio` call
directly:

| Vendor (`wiringPi`/`gpio`) | `libgpiod` |
|---|---|
| `gpio -g mode N up` / `in` | `gpioget -b pull-up` |
| `gpio -g read N` | `gpioget` |
| `gpio -g mode N out`; `write` | `gpioset` |
| `gpio -g wfi N falling` | `gpiomon -e falling -n 1` |

One caution: `gpioset` releases the line on exit, where `wiringPi` left the
pin latched. The boot-signal handshake is a multi-edge pulse train on a
single GPIO, so it must be driven from a **single** held invocation, not
several sequential ones — separate `gpioset` calls would each drop the line
between pulses and the MCU would see a malformed waveform.

**1-Wire must stay off GPIO-4 on a Raspberry Pi.** The manual calls this out
as a boot-failure cause: `dtoverlay=w1-gpio` defaults to GPIO-4, which is
this controller's halt-request line.

The vendor's own installer isn't a good starting point for an immutable or
non-Debian-based image either way — it assumes `apt`, a SysV init script,
appends to `/etc/modules` and `/boot/config.txt`, and fetches an unpinned
"latest" zip plus a `curl | bash` web-UI installer over the network, none of
which suits a reproducible build.
