#!/bin/sh
# Back up everything the Witty Pi 4 will tell us over I2C, before a flash.
#
# ── What this can and cannot capture ────────────────────────────────────────
# This is NOT a flash dump. The AVR's program memory, its fuses, and the raw
# EEPROM image are reachable only through an ISP programmer — that's a bench
# step that has to happen with the programmer already connected, see
# firmware/wittypi/README.md, and it needs to happen BEFORE the first write,
# because the flash erases EEPROM and a chip erase takes the fuses' word for
# it.
#
# What it DOES capture is the whole I2C-visible state: registers 0-49, which
# are a 1:1 mirror of the EEPROM bytes the firmware persists, plus the proxied
# PCF85063 and LM75B registers at 50-71. For configuration that is complete —
# every byte the controller will use after a flash comes from that range or
# from the firmware's own seeds.
#
# ── Why it matters more than it sounds ──────────────────────────────────────
# Register 37 is the RTC calibration offset and it is a FACTORY value, not a
# default: initializeRegisters() never seeds it, so a virgin board reads 0. A
# calibrated board reads whatever the PCF85063 was trimmed to — a measured
# property of one crystal, written at manufacture, that nothing in this repo
# could regenerate. UUGear's own flashing instructions say to save it by hand
# and write it back afterwards.
#
# So this file exists to make that not a hand step, and to make the result a
# committed artifact rather than a note in someone's terminal scrollback.
#
# usage:  backup-controller.sh [--host root@ADDR] [--out DIR]
#         with no --host it reads the LOCAL controller (run it on the board)
set -eu

HOST=""; OUT="."
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST=$2; shift ;;
        --out)  OUT=$2; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

run() {
    if [ -n "$HOST" ]; then
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$HOST" "$1"
    else
        sh -c "$1"
    fi
}

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
mkdir -p "$OUT"
BASE="$OUT/wittypi-$STAMP"

printf 'reading controller%s...\n' "${HOST:+ on $HOST}"

# Every register, not the curated set `wittypi regs` prints. That set is the
# ones this design uses; a backup wants the ones it does NOT use as well,
# because those are exactly where an unrecognised factory value would hide.
# 50-71 are the proxied RTC and temperature sensor.
# shellcheck disable=SC2016  # $r and $(wittypi ...) must expand on the TARGET,
# not here — this string is the command sent to the board, not one we run.
RAW=$(run 'for r in $(seq 0 71); do printf "%s %s\n" "$r" "$(wittypi get $r 2>/dev/null || echo ERR)"; done')

{
    printf '# Witty Pi 4 controller backup\n'
    printf '# taken   : %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '# host    : %s\n' "${HOST:-local}"
    printf '# I2C-visible state only. Program flash, fuses and the raw EEPROM\n'
    printf '#    image need an ISP programmer and are NOT in this file.\n'
    printf '#\n'
    printf '# reg value  name                 meaning\n'
    printf '%s\n' "$RAW"
} > "$BASE.raw"

# A second form, machine-readable and restore-shaped, because a backup you have
# to retype is a backup you will retype wrongly.
{
    printf '# Restore fragment for /data/wittypi.env — the values that are OURS to set.\n'
    printf '# Generated %s UTC from %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "${HOST:-local}"
    printf '#\n'
    printf '# Registers this policy does NOT own are listed as comments below rather\n'
    printf '#    than as settings, because writing them back blindly would undo a\n'
    printf '#    deliberate change as readily as it would restore an accident.\n\n'
    # The trims must be written back SIGNED, not raw. Registers 24/25/26 hold
    # a SIGNED byte: a trim of -0.05 V is stored as 251. wp_signed_byte()
    # refuses anything above 127, so a raw 251 in the env file would make
    # `wittypi configure` exit 2 — on a board that had just lost its EEPROM
    # and had nothing else to fall back on. A backup that cannot be restored
    # is not a backup, and the only time you'd find out is the one time it
    # matters.
    #
    # Register 37 is NOT signed here: the policy range-checks it as a plain
    # 0-255 byte, matching how the PCF85063 takes it, so it round-trips raw.
    for pair in "37:WITTYPI_RTC_OFFSET:raw" "24:WITTYPI_ADJ_VIN:signed" \
                "25:WITTYPI_ADJ_VOUT:signed" "26:WITTYPI_ADJ_IOUT:signed"; do
        r=$(printf '%s' "$pair" | cut -d: -f1)
        k=$(printf '%s' "$pair" | cut -d: -f2)
        kind=$(printf '%s' "$pair" | cut -d: -f3)
        v=$(printf '%s\n' "$RAW" | awk -v want="$r" '$1 == want {print $2}')
        if [ -z "$v" ] || [ "$v" = ERR ]; then continue; fi
        if [ "$kind" = signed ] && [ "$v" -gt 127 ]; then
            v=$(( v - 256 ))
        fi
        printf '%s=%s\n' "$k" "$v"
    done
    printf '\n# --- everything else, for reference ---\n'
    printf '%s\n' "$RAW" | while read -r r v; do
        printf '#  reg %-3s = %s\n' "$r" "$v"
    done
} > "$BASE.env"

printf '%s\n' "$RAW" | awk '{printf "%s ", $2}' | md5sum | cut -d' ' -f1 > "$BASE.md5"

printf 'wrote:\n  %s.raw\n  %s.env\n  %s.md5\n' "$BASE" "$BASE" "$BASE"
printf '\nthe values that CANNOT be regenerated if lost:\n'
printf '%s\n' "$RAW" | awk '$1 == 37 {printf "  register 37 RTC_OFFSET = %s   (factory crystal calibration)\n", $2}'
