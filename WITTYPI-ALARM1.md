# ALARM1 — the wake, and everything that decides whether it fires

Alarm1 is the only mechanism that brings the board back on schedule. If it
doesn't fire, the board stays off until guaranteed wake (register 49) or a
manual button press. Register behavior below is read from the firmware
source (`witty/Witty-Pi-4/Firmware/WittyPi4/WittyPi4.ino`) and confirmed on
hardware.

See also: [`WITTYPI.md`](WITTYPI.md) for the controller as a whole.

---

## The registers

| reg | name | notes |
|---|---|---|
| **27** | `SECOND_ALARM1` | BCD |
| **28** | `MINUTE_ALARM1` | BCD |
| **29** | `HOUR_ALARM1` | BCD |
| **30** | `DAY_ALARM1` | BCD, **day of month** |
| **31** | `WEEKDAY_ALARM1` | BCD; unused by this design |
| 9 | `ALARM1_TRIGGERED` | the latch — 1 once it has fired |
| 39 | `FLAG_ALARM1` | "triggered and not yet processed" |
| 49 | `GUARANTEED_WAKE` | the backstop, hours. **26** here |
| 11 | `ACTION_REASON` | `1` = woke on alarm1, `8` = delayed, `12` = guaranteed wake |

**BCD** means the decimal digits read as hex: day 16 is stored as `0x16` = 22
decimal. Every tool in this tree writes it as `0x%02d` for that reason.

---

## There is no month and no year

The firmware builds a pseudo-timestamp from four fields and nothing else
(`:1027`):

```c
long getTimestamp(byte date, byte hours, byte minutes, byte seconds) {
  return (long)date * 86400 + (long)hours * 3600 + (long)minutes * 60 + seconds;
}
```

Everything below follows from that one line.

- **The largest interval expressible is one month.** An alarm is a
  day-of-month plus a time; there is nowhere to say *which* month.
- **A month-end rollover is untested.** Day 15 → 16 is proven (below); day
  31 → 1 crosses a boundary where `date` resets and the pseudo-timestamp goes
  *backwards* by a month's worth of seconds.
- **The day is the high-order field.** That is what makes the write ordering
  below safe, and what makes a half-written alarm *almost always* harmless —
  with one midnight exception, derived below.

---

## The match: a two-second window, once per armed alarm

`processAlarmIfNeeded()` runs once a second (`:849`, from the 1 Hz watchdog)
and compares the MCU's own copy of the alarm against the RTC:

```c
long overdue_alarm1 = cur_ts - alarm1_ts;
if (canTrigger && !alarm1HasTriggered && overdue_alarm1 >= 0 && overdue_alarm1 < 2) {
```

Two seconds wide — the clock is compared once a second, so a missed second is
a missed wake.

`canTriggerAlarm()` (`:823`) gates it, and on a USB-C-powered board it is not
a gate at all:

```c
if (powerIsOn || i2cReg[I2C_POWER_MODE] == 0) return true;
```

`POWER_MODE` is 0 on the USB-C topology, so the low-voltage and
recovery-voltage conditions below that line are unreachable there. On a VIN
topology they are live and can suppress a wake.

### It fires exactly once

`alarm1HasTriggered` is true when the latch is set **or when the timestamp is
zero** (`:872`):

```c
boolean alarm1HasTriggered = (alarm1_ts == 0 || i2cReg[I2C_ALARM1_TRIGGERED] == 1);
```

So all-zero registers mean "no alarm", and a fired alarm stays fired. The
only thing that clears the latch is a write to one of registers 27-31
(`:602`):

```c
if (i2cIndex >= I2C_CONF_SECOND_ALARM1 && i2cIndex <= I2C_CONF_WEEKDAY_ALARM1) {
  updateRegister(I2C_ALARM1_TRIGGERED, 0);
}
```

Nothing rearms the alarm automatically. A scheduled shutdown consumes its own
wake; rearming for the next cycle is the caller's job.

---

## The four states

The registers hold more than "set" and "unset":

| state | 27-30 | firmware sees | a reader must say |
|---|---|---|---|
| **cleared** | `0 0 0 0` | `alarm1_ts == 0` → treated as already triggered | no wake armed |
| **armed** | e.g. `65 19 4 22` | a real future timestamp | wake at day 16, 04:13:41 |
| **half-written** | `65 19 4 0` | `ts = 15221`, a day-0 time a whole day in the past | **no wake armed** (see the midnight exception) |
| **fired** | armed values, latch = 1 | `alarm1HasTriggered` | no wake armed |

The half-written state happens when a write is interrupted between the hour
and day fields — for example a killed process — leaving the day at zero
while the time fields are set.

With `date = 0` the timestamp is at most 86399, while any real day makes
`cur_ts` at least 86400 — normally a full day away from matching, so the
alarm is inert.

One exception exists: searching every day-0 alarm time against the clock
near midnight finds exactly one matching combination in 86,400:

```
alarm  day 00 at 23:59:59      overdue = 1  -> MATCHES
clock  day  1 at 00:00:00
```

A half-written alarm whose time landed on `23:59:59` fires at midnight on the
**1st of a month**. One second earlier in the alarm, or one second later on
the clock, and `overdue` reaches 2 and the window closes.

This is why the interrupt handler clears the **seconds** field as well as the
day: a cleared seconds field moves the partial timestamp to `23:59:00`, 59
seconds outside the only window that could match.

Inert is not the same as absent: a reader that only tests for all-zero will
treat a half-written alarm as armed. Any consumer of these registers should
validate the day against 1-31, not just check for non-zero.

---

## Write ordering, and clear ordering (they are opposites)

**To arm: second, minute, hour, DAY LAST.**

The day is the high-order field, so every intermediate state carries the
*old* day. If the old day is stale, the partial timestamp is far from now and
cannot land inside a 2 s window. Writing the day first would create an
instant where the day is correct and the time fields are not — a timestamp
that *can* match, firing a wake nobody asked for.

The latch clears on the first write in the sequence, so from that moment
until the day lands, the alarm is armed with a partial value — the ordering
is what keeps that window safe.

**To clear: DAY FIRST, then the time fields.**

The inverse, for the inverse reason: zeroing the day collapses the timestamp
into the deep past immediately, where nothing can match while the rest is
still being cleared.

Any caller that arms or clears an alarm should implement both orderings.

### If the write is interrupted

A well-behaved caller traps `TERM`/`INT` — e.g. a systemd stop timeout — and
clears the day and seconds fields on the way out, so an interrupted arm
leaves an unambiguous state instead of a plausible-looking one. A failed
read-back should back the whole alarm out to zero for the same reason.

---

## An alarm that lands while the node is awake

It is not lost, and it does not cut power (`:884`):

```c
} else {
  // power is not cut yet, will power on later if alarm1 delay is allowed
  if ((i2cReg[I2C_CONF_MISC] & 0x01) == 0) { alarm1Delayed = 1; }
}
```

The counter only advances while `!powerIsOn` (`:690`), so the wake is
**deferred until after the next power-off** and then applied four ticks
later, with `ACTION_REASON` = **8** (`REASON_ALARM1_DELAYED`) rather than 1.

Register 48 bit 0 (`MISC`) disables that behaviour.

---

## The RTC has its own alarm, and it is not the one that wakes you

The PCF85063 has hardware alarm registers, proxied as 65-69. The MCU copies
its alarm into them only in the second *before* a match, in the
`-2 <= overdue < 0` branch (`:897`):

```c
} else if (!alarm1HasTriggered && overdue_alarm1 < 0 && overdue_alarm1 >= -2) {
  reset_rtc_alarm();
  copyAlarm(I2C_CONF_SECOND_ALARM1);
}
```

So **the wake decision is the MCU's 1 Hz software comparison**, not the RTC
interrupt. The RTC alarm is a same-second backup.

`reset_rtc_alarm()` is the only caller that clears the RTC's alarm flag, and
it only runs when a new alarm is armed — nothing clears it when a schedule
simply ends, so a spent appointment can leave a latched `AF` flag. Harmless
while wake decisions come from the software comparison; a real bug if
anything ever relies on the RTC's INT line.

---

## The backstops, in order

1. **alarm1** — the schedule. Fires once, in a 2 s window.
2. **a wake-guard supervisor** — before the rail is cut, if no usable alarm
   is armed, arms one fallback minutes out. A backstop, not a scheduler: it
   never overwrites an existing alarm, and refuses to act on registers it
   could not read rather than writing over a schedule it cannot see.
3. **guaranteed wake** — register 49, **26 h** here. Reason code **12**,
   worth escalating to high-priority alerting since it means a scheduled wake
   was *missed*.
4. **the button** — a site visit.

---

## Proven, and not

**Proven on hardware** — every wake attributable to alarm1 (`ACTION_REASON` = 1):

| | |
|---|---|
| Windows from **2 min to 20 min** | nothing depends on the length of the sleep |
| **A date boundary** | 23:53:53 day 15 → 00:03:53 day 16; the day register rolled and still matched |
| **From slot B** as well as slot A | |
| The half-written state | detected and repaired by a day-range check |
| Supervisor arming and idempotence | armed +60 min, verified read-back, left alone on re-run |

**Not proven:**

| | |
|---|---|
| **Month-end and year-end rollover** | day 31 → 1 is where the day-based timestamp goes backwards. Untested |
| **Guaranteed wake has never fired** | register 49 = 26 h, reason 12 never observed |
| **Schedule renewal** | alarm1-first, RTC-anchored rearming logic — offline-verified, multi-cycle hardware run pending |
| **A missed window** | the 2 s window has never been observed to close on a real wake |
| **VIN-topology gating** | `canTriggerAlarm()`'s voltage conditions are unreachable at `POWER_MODE = 0` |

---

## Reading and writing it by hand

```sh
# What is armed right now, decoded
/usr/libexec/site/wake-guard check

# Raw, if you want to see the registers themselves (BCD)
for r in 27 28 29 30; do printf '%s=%s ' "$r" "$(wittypi get "$r")"; done; echo

# Arm for 04:13:41 on day 16 — SECOND, MINUTE, HOUR, DAY LAST
wittypi set 27 0x41
wittypi set 28 0x13
wittypi set 29 0x04
wittypi set 30 0x16

# Clear — DAY FIRST
for r in 30 29 28 27; do wittypi set "$r" 0; done
```

`wittypi get 9` reads the latch: if it's 1, the alarm has already fired and
won't fire again until one of registers 27-31 is rewritten.
