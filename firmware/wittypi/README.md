# Witty Pi 4 firmware — deltas from stock

Patches against the vendor firmware (**V4.23**, commit `d466cbc`,
`Firmware/WittyPi4/WittyPi4.ino`). They live here rather than in a vendor
checkout so the delta is reviewable, version-controlled next to the driver
that depends on it, and reversible.

**Nothing in this directory is built by Yocto or any other build system.**
The controller is an ATtiny841 and the image is flashed by hand. That's
precisely why the patches carry their whole rationale in the header: there's
no CI to catch a mistake, and a deployed, unreachable board has no second
chance.

## Applying

```bash
cd <vendor-checkout>                       # V4.23 / d466cbc
git apply --check <this-dir>/0001-*.patch  # ALWAYS check first
git apply         <this-dir>/0001-*.patch
```

## The patches

| | |
|---|---|
| [`0001-fail-on-not-fail-dark.patch`](0001-fail-on-not-fail-dark.patch) | Inverts register 17 (`!= 0x5A`) so one value waits for the button and 255 powers on; masks register 47 with `& 0x1F` at the point of use so the 16-bit `delay()` overflow (see `WITTYPI.md`) is unreachable; seeds `POWER_CUT_DELAY = 200` (20.0 s). Diverges from the vendor on register 17's meaning: their `0 = no` now means **on** — use **90** for "wait for the button". Built hex in [`build/`](build/). |

This patch lands the firmware at exactly 8192 of 8192 bytes — the flash is
full. Anything further (e.g. reducing what EEPROM persists to fix write
wear on a VIN topology) would need bytes freed elsewhere first, such as a
float-to-fixed-point conversion of the voltage path.

## Before the first write — back up what only a programmer can reach

`backup-controller.sh` captures everything the controller will say over I2C
and commits it here. **It is not a flash dump.** Program memory, fuses and
the raw EEPROM image need the ISP programmer, so they must be read in the
same session as the flash, *before* the first write:

```bash
# raw flash, EEPROM and fuses — the only chance is before the erase
avrdude -c usbasp -p attiny841 -U flash:r:wp4-flash-backup.hex:i
avrdude -c usbasp -p attiny841 -U eeprom:r:wp4-eeprom-backup.hex:i
avrdude -c usbasp -p attiny841 -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h
```

**The flash erases EEPROM** — UUGear say so outright. That's why the
register backup exists and why it belongs in version control rather than
left in scrollback.

### The one value nothing can regenerate

Register **37** is the PCF85063 calibration offset. `initializeRegisters()`
never seeds it, so a virgin board reads 0 — any non-zero value is a measured
property of that specific crystal, written at manufacture or by a prior
calibration. Register 56, the live RTC offset register, mirrors it when it's
genuinely in force.

Treat it as policy (e.g. `WITTYPI_RTC_OFFSET` in your site config) so your
configuration tooling restores it at every boot, rather than depending on
someone remembering to set it once by hand.

### Calibration, and why order matters

The vendor procedure is manual: measure with a meter (and a known load for
Iout), then set a signed trim in hundredths, range −1.27…+1.27. The firmware
just adds it: `getAdjustValue() = (char)reg / 100.0`.

| | firmware seed | worth policy-managing? |
|---|---|---|
| 24 `ADJ_VIN` | 20 | yes |
| 25 `ADJ_VOUT` | 20 | yes |
| 26 `ADJ_IOUT` | not seeded → 0 | yes |

**Calibrate after the flash, or put all three trims in your site config
before you flash.** If only some of the trims are managed by your
configuration tooling, a trim that isn't will silently revert to its
firmware seed on the next config-apply — a disagreement that looks like
hardware drift rather than a config gap.

## Read before flashing anything

[`WITTYPI.md`](../../WITTYPI.md) §"Reflashing the controller" is the owning
document. Three facts that surprise people:

1. **The firmware validates nothing.** No CRC, no magic, no version, no
   range check. The EEPROM is a flat shadow of registers 0-49, and any byte
   that isn't 255 is adopted verbatim as policy.
2. **EEPROM wins.** Changing a default in `initializeRegisters()` does
   nothing on a board that's already been configured. Erase the EEPROM when
   you flash — `0001` is what makes that safe to do (see "What now
   guarantees the board returns" in `WITTYPI.md`).
3. **A bumped `I2C_FW_REVISION` is invisible unless you erase EEPROM**,
   because register 12 is inside the shadow — and it can't be corrected
   from Linux, since writes are only accepted from register index 16 up.

## Still open

- **Magic + version, validated on load, re-seeding from firmware on
  mismatch.** This is the only thing that turns a corrupted EEPROM into a
  *recovered* one rather than an *adopted* one. It needs a layout decision
  (where the magic lives, what a version bump means for an in-service
  board) and a flash-budget fix before it fits — `0001` alone already uses
  every spare byte.
- **Telling boards apart from Linux.** There's no register that says which
  firmware is running — the revision register is shadowed by EEPROM (a bumped
  `I2C_FW_REVISION` stays invisible unless EEPROM is erased), so
  identification today is by reading flash back and comparing against the
  built hex, which verifies the whole image rather than one byte. A site
  marker register would need the same flash-budget headroom as the item
  above.
