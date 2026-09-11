#!/bin/sh
# Witty Pi 4 register access — sourced by every other wittypi script.
#
# WHY THIS EXISTS RATHER THAN THE VENDOR'S utilities.sh
# -----------------------------------------------------
# The vendor ships 697 lines of utilities.sh, and essentially none of it can run
# here. It calls wiringPi's `gpio` (deprecated upstream, 24 sites), leans on GNU
# `date` semantics at ~70 sites where a busybox image has ash's, reads and
# rewrites /boot/config.txt on a READ-ONLY rootfs, and greps /etc/os-release to
# decide which Raspberry Pi OS release it is on.
#
# What is actually needed is small: read and write registers on an I2C slave,
# and drive two GPIO lines. That is this file.
#
# The register numbers are read from the vendor firmware source
# (witty/Witty-Pi-4/Firmware/WittyPi4/WittyPi4.ino) and cross-checked against
# the User Manual. Where the two disagree, the firmware wins and the
# disagreement is recorded in WITTYPI.md — see the firmware-revision warning
# at the top of that document, because it decides whether register 49 does
# anything at all.

# ── shellcheck: this file is a CONSTANTS LIBRARY ───────────────────────────
# SC2034 ("appears unused") fires on every register number here, because their
# only users are the scripts that source this file and shellcheck analyses one
# file at a time. Disabled at file scope rather than by dropping SC2034 from
# tests/lint.sh: everywhere else in this layer an unused variable is a real
# finding, and the gate should keep saying so.
# shellcheck disable=SC2034

# ── Configuration ──────────────────────────────────────────────────────────
# Overridable through the systemd unit's Environment=, which is how machine
# differences stay out of the script bytes.
WP_BUS="${WITTYPI_BUS:-1}"
WP_ADDR="${WITTYPI_ADDR:-0x08}"

# BCM numbering, from the manual. The Witty Pi uses GPIO-4, GPIO-17 and the
# I2C pair; it MONITORS GPIO-14/TXD without driving it.
WP_HALT_PIN="${WITTYPI_HALT_PIN:-4}"
WP_SYSUP_PIN="${WITTYPI_SYSUP_PIN:-17}"

# ── Registers ──────────────────────────────────────────────────────────────
# Read-only telemetry and state.
WP_REG_ID=0                 # firmware id, expect 0x26
WP_REG_VIN_INT=1
WP_REG_VIN_DEC=2
WP_REG_VOUT_INT=3
WP_REG_VOUT_DEC=4
WP_REG_IOUT_INT=5
WP_REG_IOUT_DEC=6
WP_REG_POWER_MODE=7         # 1 = via LDO/DC-DC (VIN), 0 = 5V USB-C
WP_REG_LV_SHUTDOWN=8
WP_REG_ALARM1_TRIGGERED=9
WP_REG_ALARM2_TRIGGERED=10
WP_REG_ACTION_REASON=11
WP_REG_FW_REVISION=12       # <7 means no guaranteed wake — see WITTYPI.md

# Configuration.
WP_REG_DEFAULT_ON=17
WP_REG_PULSE_INTERVAL=18    # seconds between sleep-time housekeeping pulses
WP_REG_LOW_VOLTAGE=19       # x10, 255 = disabled
WP_REG_BLINK_LED=20         # ms the white LED stays on per pulse, 0 = never
WP_REG_POWER_CUT_DELAY=21   # x10
WP_REG_RECOVERY_VOLTAGE=22  # x10, 255 = disabled
WP_REG_DUMMY_LOAD=23        # ms the output is re-asserted per pulse, 0 = never
WP_REG_ADJ_VIN=24           # signed hundredths of a volt
WP_REG_ADJ_VOUT=25          # signed hundredths of a volt
WP_REG_ADJ_IOUT=26          # signed hundredths of an amp
WP_REG_RTC_OFFSET=37        # PCF85063 calibration; PER BOARD, erased by a flash
WP_REG_RTC_ENABLE_TC=38     # 1 = temperature compensation on

# ── Alarm1/alarm2, the ATtiny's OWN registers — NOT the proxied PCF85063
# alarm block (65-69), which is a different mechanism with a different
# encoding (bit 7 = disabled). These five per-alarm registers are read by
# processAlarmIfNeeded() (WittyPi4.ino) with a plain bcd2dec each — no
# disable-bit convention here at all.
#
# WEEKDAY (31/36) is defined by the firmware but never compared — confirmed
# by reading processAlarmIfNeeded() directly: it reads SECOND/MINUTE/HOUR/DAY
# for both alarms and never touches WEEKDAY_ALARM1/2 at all. Named here for
# an honest register dump, not because writing it does anything.
WP_REG_ALARM1_SEC=27        # startup alarm, BCD, regs 27..31
WP_REG_ALARM1_MIN=28
WP_REG_ALARM1_HOUR=29
WP_REG_ALARM1_DAY=30
WP_REG_ALARM1_WEEKDAY=31    # defined, never read by the firmware's alarm match
WP_REG_ALARM2_SEC=32        # shutdown alarm, BCD, regs 32..36
WP_REG_ALARM2_MIN=33
WP_REG_ALARM2_HOUR=34
WP_REG_ALARM2_DAY=35
WP_REG_ALARM2_WEEKDAY=36    # defined, never read by the firmware's alarm match
WP_REG_FLAG_ALARM1=39       # "triggered and not yet processed"
WP_REG_FLAG_ALARM2=40
WP_REG_IGNORE_POWER_MODE=41 # 1 forces the low-voltage path on in USB-C mode
WP_REG_IGNORE_LV_SHUTDOWN=42
WP_REG_BELOW_TEMP_ACTION=43
WP_REG_BELOW_TEMP_POINT=44
WP_REG_OVER_TEMP_ACTION=45
WP_REG_OVER_TEMP_POINT=46
WP_REG_DEFAULT_ON_DELAY=47  # seconds — see WP_EEPROM_UNSET before writing 255
WP_REG_MISC=48
WP_REG_GUARANTEED_WAKE=49   # bits 0-6 duration, bit 7 unit (0=hours 1=days)

# Register 13. Carries no vendor definition (reserved for future use) and
# nothing in this firmware writes it — identification of which firmware a
# board is running is by reading flash back and comparing against the built
# hex (see firmware/wittypi/README.md), not by a register. Named here purely
# so a register dump reports it as SITE_MARK rather than a bare number.
WP_REG_SITE_MARK=13

# ── NAMES AND MEANINGS ─────────────────────────────────────────────────────
# A register dump of bare bytes is a dump nobody reads carefully — `44 236`
# is correct and tells you nothing; `BELOW_TEMP_POINT  236  -20 C` is the
# same fact in a form where a wrong value looks wrong. Both columns are
# kept — the raw byte is what you compare against the datasheet and what
# you would write back, and the decode is what makes an error visible at a
# glance.

wp_reg_name() {
    case "$1" in
        0)  echo ID ;;                    1)  echo VIN_INT ;;
        2)  echo VIN_DEC ;;               3)  echo VOUT_INT ;;
        4)  echo VOUT_DEC ;;              5)  echo IOUT_INT ;;
        6)  echo IOUT_DEC ;;              7)  echo POWER_MODE ;;
        8)  echo LV_SHUTDOWN ;;           9)  echo ALARM1_TRIGGERED ;;
        10) echo ALARM2_TRIGGERED ;;      11) echo ACTION_REASON ;;
        12) echo FW_REVISION ;;           13) echo SITE_MARK ;;
        17) echo DEFAULT_ON ;;            18) echo PULSE_INTERVAL ;;
        19) echo LOW_VOLTAGE ;;           20) echo BLINK_LED ;;
        21) echo POWER_CUT_DELAY ;;       22) echo RECOVERY_VOLTAGE ;;
        23) echo DUMMY_LOAD ;;            24) echo ADJ_VIN ;;
        25) echo ADJ_VOUT ;;              26) echo ADJ_IOUT ;;
        27) echo ALARM1_SEC ;;            28) echo ALARM1_MIN ;;
        29) echo ALARM1_HOUR ;;           30) echo ALARM1_DAY ;;
        31) echo ALARM1_WEEKDAY ;;        32) echo ALARM2_SEC ;;
        33) echo ALARM2_MIN ;;            34) echo ALARM2_HOUR ;;
        35) echo ALARM2_DAY ;;            36) echo ALARM2_WEEKDAY ;;
        37) echo RTC_OFFSET ;;             38) echo RTC_ENABLE_TC ;;
        39) echo FLAG_ALARM1 ;;           40) echo FLAG_ALARM2 ;;
        41) echo IGNORE_POWER_MODE ;;     42) echo IGNORE_LV_SHUTDOWN ;;
        43) echo BELOW_TEMP_ACTION ;;     44) echo BELOW_TEMP_POINT ;;
        45) echo OVER_TEMP_ACTION ;;      46) echo OVER_TEMP_POINT ;;
        47) echo DEFAULT_ON_DELAY ;;      48) echo MISC ;;
        49) echo GUARANTEED_WAKE ;;
        # ── The proxy block. NOT the MCU's own registers ────────────────────
        # 50-53 are the LM75B and 54-71 the PCF85063, forwarded over the MCU's
        # internal bus. This is why i2cdetect shows 0x08 alone and why there is
        # no /dev/rtc: to Linux they are not devices, they are addresses on one
        # slave. Named here because a backup that lists 22 bare numbers is a
        # backup nobody will read.
        50) echo LM75B_TEMPERATURE ;;      51) echo LM75B_CONF ;;
        52) echo LM75B_THYST ;;            53) echo LM75B_TOS ;;
        54) echo RTC_CTRL1 ;;              55) echo RTC_CTRL2 ;;
        56) echo RTC_OFFSET_LIVE ;;        57) echo RTC_RAM_BYTE ;;
        58) echo RTC_SECONDS ;;            59) echo RTC_MINUTES ;;
        60) echo RTC_HOURS ;;              61) echo RTC_DAYS ;;
        62) echo RTC_WEEKDAYS ;;           63) echo RTC_MONTHS ;;
        64) echo RTC_YEARS ;;              65) echo RTC_SECOND_ALARM ;;
        66) echo RTC_MINUTE_ALARM ;;       67) echo RTC_HOUR_ALARM ;;
        68) echo RTC_DAY_ALARM ;;          69) echo RTC_WEEKDAY_ALARM ;;
        70) echo RTC_TIMER_VALUE ;;        71) echo RTC_TIMER_MODE ;;
        *)  echo "-" ;;
    esac
}

# Accept a NAME or a NUMBER anywhere a register is expected, so `wittypi get
# POWER_CUT_DELAY` and `wittypi get 21` are the same request. Names are matched
# case-insensitively and an optional WP_REG_/I2C_CONF_ prefix is tolerated,
# because those are what the lib and the firmware call them respectively and
# nobody should have to remember which.
wp_reg_num() {
    case "$1" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$1"; return 0 ;;
    esac
    wp_rn_want=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
    wp_rn_want=${wp_rn_want#WP_REG_}
    wp_rn_want=${wp_rn_want#I2C_CONF_}
    wp_rn_want=${wp_rn_want#I2C_}
    for wp_rn_i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 17 18 19 20 21 22 23 24 25 \
                   26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 \
                   45 46 47 48 49; do
        if [ "$(wp_reg_name "$wp_rn_i")" = "$wp_rn_want" ]; then
            printf '%s' "$wp_rn_i"; return 0
        fi
    done
    printf 'not a register name or number: %s\n' "$1" >&2
    return 1
}

wp_signed() { [ "$1" -gt 127 ] && echo $(( $1 - 256 )) || echo "$1"; }
wp_bcd()    { printf '%s' $(( ( ${1:-0} / 16 ) * 10 + ( ${1:-0} % 16 ) )); }

wp_reason_name() {
    case "$1" in
        0)  echo "none recorded" ;;      1)  echo "alarm1 (scheduled startup)" ;;
        2)  echo "alarm2 (scheduled shutdown)" ;;
        3)  echo "button click" ;;       4)  echo "low voltage" ;;
        5)  echo "voltage restored" ;;   6)  echo "over temperature" ;;
        7)  echo "below temperature" ;;  8)  echo "alarm1 delayed" ;;
        10) echo "power connected" ;;    11) echo "reboot" ;;
        12) echo "guaranteed wake" ;;    *)  echo "unknown ($1)" ;;
    esac
}

wp_temp_action() {
    case "$1" in
        0) echo "nothing" ;; 1) echo "shut down" ;; 2) echo "start up" ;;
        *) echo "unknown ($1)" ;;
    esac
}

# wp_reg_decode <reg> <raw> [site-mark-raw]
#
# The third argument exists for register 17 alone, and it is the honest part of
# this whole feature: what a byte in DEFAULT_ON MEANS depends on which firmware
# is running. Stock powers on only for 1; the site firmware powers on for
# everything except 0x5A. Decoding it without knowing which would be a
# confident guess, so when the marker is not supplied the decode says so.
wp_reg_decode() {
    wp_rd_r=$1; wp_rd_v=$2; wp_rd_mark=${3:-}
    case "$wp_rd_r" in
        0)  [ "$wp_rd_v" = 38 ] && echo "0x26, the expected id" || echo "0x$(printf '%02x' "$wp_rd_v") — NOT 0x26" ;;
        1|3)   echo "${wp_rd_v} V (integer part)" ;;
        2|4)   echo "0.$(printf '%02d' "$wp_rd_v") V (hundredths)" ;;
        5)     echo "${wp_rd_v} A (integer part)" ;;
        6)     echo "0.$(printf '%02d' "$wp_rd_v") A (hundredths)" ;;
        7)  [ "$wp_rd_v" = 1 ] && echo "VIN, via the DC/DC" || echo "5 V straight in (USB-C)" ;;
        8|9|10|39|40|41|42|48)
            [ "$wp_rd_v" = 0 ] && echo "no" || echo "yes" ;;
        11) wp_reason_name "$wp_rd_v" ;;
        12) echo "vendor revision $wp_rd_v" ;;
        13) echo "unused — the site marker did not fit; identify firmware by flash checksum" ;;
        # Register 17 means different things on different firmware, and
        # nothing on the board can tell you which. Stock powers on only for
        # 1; the site firmware powers on for everything except 0x5A. The
        # site marker that would have distinguished them was dropped — the
        # flash is full — so this states BOTH readings rather than guessing
        # one. A confident wrong answer here reads as "this board will come
        # back" about a board that will not.
        17)
            case "$wp_rd_v" in
                1)  echo "on when power returns (both firmwares)" ;;
                90) echo "site fw: WAITS FOR THE BUTTON · stock: on" ;;
                0)  echo "stock: WAITS FOR THE BUTTON · site fw: on" ;;
                *)  echo "stock: WAITS FOR THE BUTTON · site fw: on" ;;
            esac ;;
        18|47) echo "${wp_rd_v} s" ;;
        # Plain BCD, no disable bit — don't reuse the 65-69 pattern here.
        # These are the ATtiny's own alarm registers, read by
        # processAlarmIfNeeded() with a bare bcd2dec each; the proxied
        # PCF85063 alarm block (65-69) is a different mechanism where bit 7
        # means disabled. Confusing the two would decode a real, armed alarm
        # hour as "disabled" or vice versa.
        27|32) echo "$(wp_bcd "$wp_rd_v")s" ;;
        28|33) echo "$(wp_bcd "$wp_rd_v") min" ;;
        29|34) echo "$(wp_bcd "$wp_rd_v") h" ;;
        30|35) echo "day $(wp_bcd "$wp_rd_v")" ;;
        31|36) echo "weekday $(wp_bcd "$wp_rd_v") — defined, unused by the firmware's match" ;;
        37)    echo "calibration $wp_rd_v — PER BOARD, a flash erases it" ;;
        38)    [ "$wp_rd_v" = 1 ] && echo "temperature compensation on" || echo "off" ;;
        19|22) [ "$wp_rd_v" = 255 ] && echo "disabled" \
                   || echo "$(( wp_rd_v / 10 )).$(( wp_rd_v % 10 )) V" ;;
        20|23) [ "$wp_rd_v" = 0 ] && echo "never" || echo "${wp_rd_v} ms" ;;
        21)    echo "$(( wp_rd_v / 10 )).$(( wp_rd_v % 10 )) s" ;;
        24|25) echo "$(wp_signed "$wp_rd_v") hundredths of a volt" ;;
        26)    echo "$(wp_signed "$wp_rd_v") hundredths of an amp" ;;
        # The RTC fields are BCD, not binary. 0x41 in the seconds register
        # is 41 seconds, not 65 — reading them as decimal is how a clock
        # that is perfectly correct looks broken, and how one that is
        # broken looks fine.
        58) echo "$(wp_bcd $(( wp_rd_v & 127 )))s$([ "$(( wp_rd_v & 128 ))" -ne 0 ] && echo ' [oscillator stopped]' || echo '')" ;;
        59) echo "$(wp_bcd "$wp_rd_v") min" ;;
        60) echo "$(wp_bcd $(( wp_rd_v & 63 ))) h" ;;
        61) echo "day $(wp_bcd $(( wp_rd_v & 63 )))" ;;
        62) echo "weekday $wp_rd_v" ;;
        63) echo "month $(wp_bcd $(( wp_rd_v & 31 )))" ;;
        64) echo "year 20$(wp_bcd "$wp_rd_v")" ;;
        50) echo "$(wp_signed "$wp_rd_v") C (live)" ;;
        52|53) echo "$(wp_signed "$wp_rd_v") C" ;;
        56) echo "live offset $wp_rd_v — should match register 37" ;;
        65|66|67|68|69)
            # if/else, not `A && B || C`. With the && || form a failing echo
            # would run the other branch, and shellcheck flags the shape for
            # exactly that reason — the PCF85063 alarm registers use bit 7 as
            # "this field is ignored", so getting the branch wrong turns a
            # disabled alarm into a real one.
            if [ "$(( wp_rd_v & 128 ))" -ne 0 ]; then
                echo "disabled"
            else
                wp_bcd $(( wp_rd_v & 127 ))
            fi ;;
        43|45) wp_temp_action "$wp_rd_v" ;;
        44|46) echo "$(wp_signed "$wp_rd_v") C" ;;
        49)
            if [ "$wp_rd_v" = 0 ]; then echo "DISABLED — no last-resort wake"
            elif [ "$(( wp_rd_v & 128 ))" -ne 0 ]; then echo "$(( wp_rd_v & 127 )) days"
            else echo "$(( wp_rd_v & 127 )) hours"; fi ;;
        *)  echo "" ;;
    esac
}

# ── 255 does not mean 255 in EEPROM ─────────────────────────────────────────
# initializeRegisters() (WittyPi4.ino:288-296) treats a stored 255 as "this
# cell was never written" and replaces it with the COMPILED default:
#
#     byte val = EEPROM.read(i);
#     if (val == 255) EEPROM.update(i, i2cReg[i]);   // <- a written 255 is discarded
#     else            i2cReg[i] = val;
#
# So any register whose intended value is 255 holds it only until the MCU next
# loses power. Survivable for LOW_VOLTAGE and RECOVERY_VOLTAGE, whose compiled
# defaults ARE 255 — the rewrite is a no-op. NOT survivable for
# DEFAULT_ON_DELAY, whose compiled default is 0 (i2cReg is a zero-initialised
# file-scope array and initializeRegisters never assigns it), and which matters
# on exactly the power-loss path that erases it. Hence 254 rather than 255 as
# the usable maximum: one second is a cheap price for a value that persists.
WP_EEPROM_UNSET=255

# ── Cross-register sanity ──────────────────────────────────────────────────
# Every rule here is a pair of registers that are individually legal and
# jointly wrong. `check` compares the board against the policy and would pass
# all of these, because each value is exactly what was asked for — the fault
# is in the combination.
#
# The temperature pair is the one that proves the point: a policy that sets
# OVER_TEMP_POINT while leaving BELOW_TEMP_POINT at whatever the board
# already holds can invert the two, since they were only ever coherent
# together. Both registers hold exactly what was intended; together they can
# say "shut down when cooler than 75C" on a board that never gets that cold —
# inert only while the below-temperature ACTION is 0, and one register away
# from a board that requests shutdown shortly after every boot, which can be
# shorter than a health-check soak and cost a boot-attempt on both A/B slots.
#
# Consumes the same reg<TAB>value<TAB>label block the policy emits, so it can
# vet a policy BEFORE it is written and the board's own registers after.
wp_pol_val() {
    printf '%s\n' "$1" | awk -F'\t' -v r="$2" '$1 == r { print $2; exit }'
}

# The only two registers whose COMPILED default is 255, and therefore the only
# two where storing 255 survives an MCU restart (initializeRegisters rewrites
# the default over it, which for these is a no-op). Anywhere else 255 means
# "never written" and erases itself — see WP_EEPROM_UNSET.
WP_255_IS_LEGAL="$WP_REG_LOW_VOLTAGE $WP_REG_RECOVERY_VOLTAGE"

# ── The other end of a range, which is easy to miss ────────────────────────
# WittyPi4.ino:253 runs `delay(i2cReg[47] * 1000)` and `int` is 16 bits on AVR,
# so the product is evaluated as an int before it is widened to delay()'s
# unsigned long. 32 * 1000 fits; 33 * 1000 does not, wraps negative, and becomes
# roughly 49.7 days. DEFAULT_ON then never fires — input power returns and the
# board stays dark.
#
# A value like 254 has actually cost a real outage this way. The vendor's own
# tool accepts 0-10 only (wittyPi.sh:380), which is easy to miss if you only
# read the register's own comment.
WP_MAX_DEFAULT_ON_DELAY=32

# ── The shutdown budget, in seconds ────────────────────────────────────────
# Everything after a shutdown REQUEST shares register 21: any bounded
# pre-shutdown gate's wait (WITTYPI_MARKGOOD_GRACE) plus the whole of Linux
# shutting down. A value below their sum cuts the rail mid-shutdown, on the
# one path where persistent storage is being unmounted.
#
# This exists because a build can't see a site's actual configured value.
# `timing-windows` owns the arithmetic — it sums the shutdown terms and
# reports whether they fit inside this delay, reading both this constant and
# the gate's own default from source so the two cannot drift. But a site's
# env file can override
# register 21 on any board, and the vendor's own default is 7s — which does
# not fit. That override is invisible to any build-time check, so the
# refusal has to live here, at runtime.
WP_MIN_POWER_CUT_DELAY=16

# The ceiling is a property of the register, not a preference. Register 21
# is deci-seconds in ONE BYTE and 255 is the never-written sentinel
# (initializeRegisters() treats a stored 255 as "unset"), so the largest
# value that can actually be held is 254 -> 25.4 s, and the usable ceiling
# is 25.
WP_MAX_POWER_CUT_DELAY=25

wp_sanity() {
    wp_sn_rc=0
    wp_sn_fail() { wp_log "SANITY: $*"; wp_sn_rc=2; }

    # ── The EEPROM sentinel, generalised ───────────────────────────────────
    # The specific case (register 47) was already refused. This is the rule it
    # was an instance of, and it now covers the SIGNED registers too, where 255
    # is -1 — an ordinary trim value that would silently revert.
    printf '%s\n' "$1" | while IFS="$(printf '\t')" read -r wp_sn_r wp_sn_v wp_sn_l; do
        [ -n "$wp_sn_r" ] || continue
        [ "$wp_sn_v" = "$WP_EEPROM_UNSET" ] || continue
        case " $WP_255_IS_LEGAL " in
            *" $wp_sn_r "*) continue ;;
        esac
        wp_log "SANITY: register $wp_sn_r ($wp_sn_l) would be written 255, which the"
        wp_log "        MCU reads as 'never written' and replaces with its compiled"
        wp_log "        default on the next power loss. Use 254, or -2 for a trim."
        printf 'x'
    done | grep -q x && wp_sn_rc=2

    # ── Temperature: the two points must be ordered ────────────────────────
    wp_sn_bp=$(wp_pol_val "$1" "$WP_REG_BELOW_TEMP_POINT")
    wp_sn_op=$(wp_pol_val "$1" "$WP_REG_OVER_TEMP_POINT")
    # Half a pair is its own fault, and skipping the rule when one side is
    # missing is how this bug gets written in the first place: a policy
    # that sets the over-temperature point and says nothing about the
    # below-temperature point leaves nothing to compare and no complaint —
    # but the two are compared against each other by the firmware whether
    # or not both are set here.
    if [ -n "$wp_sn_op" ] && [ -z "$wp_sn_bp" ]; then
        wp_sn_fail "the over-temperature point is set but the below-temperature \
point (register $WP_REG_BELOW_TEMP_POINT) is not. The firmware compares them to \
each other, so leaving one at whatever the board happens to hold is how they end \
up inverted. Set both or neither."
    fi
    if [ -n "$wp_sn_bp" ] && [ -n "$wp_sn_op" ]; then
        # Both are SIGNED on this firmware — getAdjustValue casts to char, and
        # -20 C is stored as 236. Compare as signed, or -20 reads as hotter
        # than 70 and the check passes the very case it exists for.
        [ "$wp_sn_bp" -gt 127 ] && wp_sn_bp=$(( wp_sn_bp - 256 ))
        [ "$wp_sn_op" -gt 127 ] && wp_sn_op=$(( wp_sn_op - 256 ))
        if [ "$wp_sn_bp" -ge "$wp_sn_op" ]; then
            wp_sn_fail "below-temperature point ${wp_sn_bp}C is not below the \
over-temperature point ${wp_sn_op}C. Every temperature is then 'too cold', and \
enabling register $WP_REG_BELOW_TEMP_ACTION would shut the board down on every boot."
        fi
    fi

    # ── Voltage: hysteresis must point the right way, and never half-armed ──
    wp_sn_lv=$(wp_pol_val "$1" "$WP_REG_LOW_VOLTAGE")
    wp_sn_rv=$(wp_pol_val "$1" "$WP_REG_RECOVERY_VOLTAGE")
    if [ -n "$wp_sn_lv" ] && [ -n "$wp_sn_rv" ]; then
        if [ "$wp_sn_lv" = "$WP_EEPROM_UNSET" ] && [ "$wp_sn_rv" != "$WP_EEPROM_UNSET" ]; then
            wp_sn_fail "recovery voltage is set while low voltage is disabled. \
WittyPi4.ino:407 then arms a voltage-restore wake with nothing to shut the board \
down first, so it fights the schedule instead of protecting the battery."
        elif [ "$wp_sn_lv" != "$WP_EEPROM_UNSET" ] && [ "$wp_sn_rv" != "$WP_EEPROM_UNSET" ] \
             && [ "$wp_sn_rv" -le "$wp_sn_lv" ]; then
            wp_sn_fail "recovery voltage ($wp_sn_rv) must EXCEED low voltage \
($wp_sn_lv) or the board oscillates: shut down, wake immediately, shut down."
        fi
    fi

    # ── The two settings whose absence is silent and expensive ─────────────
    wp_sn_don=$(wp_pol_val "$1" "$WP_REG_DEFAULT_ON")
    [ -n "$wp_sn_don" ] && [ "$wp_sn_don" != "1" ] && \
        wp_sn_fail "default-on is $wp_sn_don, so the board will NOT come back \
after a power interruption without someone visiting it."
    wp_sn_gw=$(wp_pol_val "$1" "$WP_REG_GUARANTEED_WAKE")
    [ -n "$wp_sn_gw" ] && [ "$wp_sn_gw" = "0" ] && \
        wp_sn_fail "guaranteed wake is 0 — WITTYPI.md layer 3 is disabled, and a \
schedule that fails to renew then leaves the board asleep permanently."

    # ── The shutdown must fit inside the power-cut delay ───────────────────
    # The register is x10 seconds. See WP_MIN_POWER_CUT_DELAY above for why the
    # build cannot check this and this can.
    wp_sn_pcd=$(wp_pol_val "$1" "$WP_REG_POWER_CUT_DELAY")
    if [ -n "$wp_sn_pcd" ] && \
       [ "$wp_sn_pcd" -lt "$(( WP_MIN_POWER_CUT_DELAY * 10 ))" ]; then
        wp_sn_fail "power-cut delay is $(( wp_sn_pcd / 10 ))s, below the \
${WP_MIN_POWER_CUT_DELAY}s the shutdown needs (a bounded pre-shutdown gate's \
wait plus a measured ~6s shutdown). The rail would be cut while persistent \
storage is still mounted, on the one path that is supposed to unmount it \
cleanly."
    fi

    return "$wp_sn_rc"
}

# ── The VIRTUAL registers — the proxy, and why i2cdetect shows only 0x08 ───
# The MCU is an I2C master on its own internal bus, and re-exposes what it finds
# there as registers 50-71 of ITS OWN slave device. So the PCF85063 and the
# LM75B are proxied by REGISTER, not by ADDRESS: they never appear at 0x51 and
# 0x48 on the Pi's bus, and `i2cdetect -y 1` showing 0x08 alone is the proxy
# working as designed, not a fault.
#
# The consequence is structural: no kernel driver can bind to a device that has
# no address, so there is no /dev/rtc and no hwmon entry. Reading the clock and
# the temperature is userspace's job, through here.
WP_REG_LM75B_TEMP=50        # 2 bytes, big-endian on the wire
WP_REG_RTC_CTRL1=54
WP_REG_RTC_SEC=58           # bit 7 is the oscillator-stop flag, mask it off
WP_REG_RTC_MIN=59
WP_REG_RTC_HOUR=60
WP_REG_RTC_DAY=61
WP_REG_RTC_WEEKDAY=62
WP_REG_RTC_MONTH=63
WP_REG_RTC_YEAR=64          # two digits; the century is ours to supply

# ── Action reasons ─────────────────────────────────────────────────────────
# 0-8 are in the manual; 10-12 exist only in firmware revision 7 and later.
WP_REASON_ALARM1=1
WP_REASON_ALARM2=2
WP_REASON_CLICK=3
WP_REASON_LOW_VOLTAGE=4
WP_REASON_VOLTAGE_RESTORE=5
WP_REASON_OVER_TEMPERATURE=6
WP_REASON_BELOW_TEMPERATURE=7
WP_REASON_ALARM1_DELAYED=8
WP_REASON_POWER_CONNECTED=10
WP_REASON_REBOOT=11
WP_REASON_GUARANTEED_WAKE=12

# The revision at which register 49 became guaranteed wake rather than
# "reserved for future usage #6". Below this the board has TWO defences, not
# three, and that's a fact about the board in hand.
WP_MIN_REV_GUARANTEED_WAKE=7

wp_log() {
    # Journal via stderr; the unit is Type=simple so this lands in the journal
    # without needing logger(1) in the image.
    printf 'wittypi: %s\n' "$*" >&2
}

# wp_log_err <message> — wp_log, but at ERR priority, which can be the
# difference between a diagnosis and a guess on a system where the journal
# doesn't survive every reboot.
#
# Why this exists: on a board with a volatile journal (common on
# space-constrained or flash-write-averse images) and a persist mechanism
# that only copies priority `err` and above to durable storage, plain stderr
# — which systemd files at `info` — can mean every warning this tooling ever
# printed gets erased by the next power cycle, leaving only systemd's own
# "Failed to start" lines (which are `err`) as evidence something went wrong,
# with no explanation of *why*.
#
# The `<3>` prefix is a systemd convention, not a string invented here:
# systemd parses a leading kernel-style `<N>` on a service's stdout/stderr as
# the syslog priority and strips it before storing the line. 3 is LOG_ERR.
#
# It's suppressed outside systemd, deliberately. These tools are built so a
# typed run and a unit run behave identically. A human at a serial console
# would see a literal "<3>" that nothing strips, because only systemd's
# stream parser does that. INVOCATION_ID is set by systemd for every service
# invocation and by nothing else, so it's the exact test for "is anyone
# going to parse this prefix".
#
# Routine success must not use this. If your persistence mechanism assumes a
# HEALTHY board writes zero bytes to flash, promoting ordinary verdicts to
# err would put a write on every boot, on flash that may not be easy to
# replace. Reserve it for states a human must be able to reconstruct after
# the fact: refusals, failed arms, and hazards.
wp_log_err() {
    if [ -n "${INVOCATION_ID:-}" ]; then
        printf '<3>wittypi: %s\n' "$*" >&2
    else
        printf 'wittypi: %s\n' "$*" >&2
    fi
}

# wp_utc_note — the deployment's UTC annotation, ready to append.
#
# Everything in this tree renders UTC and only UTC: the alarm registers are
# UTC, the firmware's match is UTC, and timing-windows spells out why (a DST
# conversion is a 3600s discontinuity against a far smaller tolerance). But a
# human reading `03:00:00 UTC` off a serial console at 3am still has to do the
# offset in their head, and that is where the mistakes are.
#
# So a site states its offsets ONCE and every timestamp carries them:
#
#     /data/wittypi.env:   WITTYPI_TZ_NOTE=ET:-4/-5
#     output:              day 12 at 03:00:00 UTC (ET:-4/-5)
#
# ⚠️ A CONSTANT STRING, NOT A CONVERSION — that is the whole point. It needs no
# tzdata (this image has none), never asks which of EDT/EST is in force today,
# and has no DST branch to be wrong in. It computes nothing, so it cannot drift.
#
# ⚠️ EMPTY BY DEFAULT, because offsets are a fact about a DEPLOYMENT and not
# about a Witty Pi 4. A driver that hardcoded one site's timezone would be the
# same category error the board-calibration registry exists to prevent.
#
# The leading space lives INSIDE the note, so every caller appends
# unconditionally and an unset note leaves the line byte-for-byte as it was.
WP_SITE_ENV="${WITTYPI_SITE_ENV:-/data/wittypi.env}"
wp_utc_note() {
    if [ -z "${WP_UTC_NOTE_READ:-}" ]; then
        WP_UTC_NOTE_READ=1
        # Environment wins (a bench override), then the site file — the same
        # precedence wittypi-audit already uses, and the same refusal to
        # EXECUTE a config file: it is grepped, never sourced.
        if [ -z "${WITTYPI_TZ_NOTE+x}" ] && [ -r "$WP_SITE_ENV" ]; then
            WITTYPI_TZ_NOTE=$(sed -n 's/^WITTYPI_TZ_NOTE=//p' "$WP_SITE_ENV" | sed -n 1p)
        fi
        WITTYPI_TZ_NOTE="${WITTYPI_TZ_NOTE:-}"
        # systemd's EnvironmentFile= accepts quotes and strips them before the
        # value reaches a unit, so a line copied from there may arrive quoted.
        # Strip one matching pair rather than printing ("ET:-4/-5").
        case "$WITTYPI_TZ_NOTE" in
            \"*\") WITTYPI_TZ_NOTE=${WITTYPI_TZ_NOTE#\"}; WITTYPI_TZ_NOTE=${WITTYPI_TZ_NOTE%\"} ;;
            \'*\') WITTYPI_TZ_NOTE=${WITTYPI_TZ_NOTE#\'}; WITTYPI_TZ_NOTE=${WITTYPI_TZ_NOTE%\'} ;;
        esac
    fi
    [ -n "$WITTYPI_TZ_NOTE" ] && printf ' (%s)' "$WITTYPI_TZ_NOTE"
    # Never let an absent note look like a failure to a caller under set -e.
    return 0
}

# ── I2C ────────────────────────────────────────────────────────────────────
# i2cget prints hex ("0x26"). POSIX arithmetic expansion parses that directly,
# which avoids depending on whether this image's printf accepts 0x for %d —
# busybox and coreutils differ, and the difference is silent.
wp_get() {
    wp_get_raw=$(i2cget -y "$WP_BUS" "$WP_ADDR" "$1" 2>/dev/null) || return 1
    [ -n "$wp_get_raw" ] || return 1
    echo $(( wp_get_raw ))
}

wp_set() {
    i2cset -y "$WP_BUS" "$WP_ADDR" "$1" "$2" 2>/dev/null
}

# Is the controller actually on the bus? Every caller must handle "no", because
# a Pi with no Witty Pi fitted is the normal bench configuration and must not
# hang or fail closed.
# ── 255 is also what a failed read looks like ──────────────────────────────
# The other 255 problem, and it is not the EEPROM one above. An I2C read that
# NAKs — no device, a glitch, or the MCU unable to service it because it is
# mid-transaction on its own internal bus — leaves SDA high and reads back as
# 0xFF, and i2cget still exits 0. There is no error to check.
#
# Measured, not assumed — and it is not only 0xFF. Register 17 (DEFAULT_ON)
# has been observed to read 0x00 and then 0x01 on two consecutive i2cget
# calls, with the comparison done on the board itself so the serial console
# is excluded as the cause. Hundreds of further reads were clean, so the
# rate is of order 0.1% or lower: rare, real, and hard to reproduce on
# demand.
#
# Two things follow, and they shaped this function:
#
#   * A rule keyed on 0xFF would have MISSED it. The glitch landed on 0x00, and
#     on register 17 that reads as "do not come back after a power
#     interruption" — the single most consequential setting on the board. So
#     the defence is AGREEMENT between reads, not suspicion of a magic value.
#   * At ~0.1% per read, a 13-register comparison has roughly a 1% chance per
#     boot of a spurious mismatch. Two agreeing reads makes that negligible.
#
# The mechanism is plausible: the software I2C slave library commonly used on
# an ATtiny for this also runs its own bit-banged master transactions and a
# once-a-second watchdog ISR, so there are windows in which it cannot answer
# cleanly.
#
# This can't be folded into wp_get, which is why it's separate. Registers
# 1/3/5 are RECOMPUTED by the firmware at the moment they are read
# (requestEvent, WittyPi4.ino:627-638), the RTC seconds tick, and the LM75B
# changes on its own. For those, two reads disagreeing is CORRECT, and a
# stability requirement would fail constantly and teach everyone to ignore it.
#
# Use this for CONFIGURATION registers only — the ones that change when
# something writes them and at no other time.
wp_get_stable() {
    wp_gs_a=$(wp_get "$1") || return 1
    wp_gs_b=$(wp_get "$1") || return 1
    if [ "$wp_gs_a" = "$wp_gs_b" ]; then
        printf '%s' "$wp_gs_a"
        return 0
    fi
    # Two disagreeing reads do not say which was wrong. A third breaks the tie
    # only if it matches one of them; three distinct values is a bus that
    # should not be trusted to configure a power controller.
    wp_gs_c=$(wp_get "$1") || return 1
    if [ "$wp_gs_c" = "$wp_gs_a" ] || [ "$wp_gs_c" = "$wp_gs_b" ]; then
        printf '%s' "$wp_gs_c"
        return 0
    fi
    wp_log "register $1 read three different values ($wp_gs_a, $wp_gs_b, \
$wp_gs_c) — the bus is not reliable enough to act on"
    return 1
}

# ── Which registers wp_get_stable is even valid for ─────────────────────────
# States the SAME exclusion wp_get_stable's own header already argues for, as
# code a caller can consult instead of re-deriving it: 1/3/5 are recomputed by
# the firmware only when THOSE registers are the one requested — confirmed by
# reading requestEvent()/getInputVoltage() et al. directly (WittyPi4.ino) —
# and the proxied RTC/temp block (50-71) ticks or floats on its own. Every
# other register, including 2/4/6 (the decimal halves — they change only as a
# side effect of reading 1/3/5, never on their own) and the alarm blocks
# (27-36), only changes when something writes it, which is exactly
# wp_get_stable's precondition.
wp_reg_is_stable_class() {
    case "$1" in
        1|3|5) return 1 ;;
        5[0-9]|6[0-9]|7[01]) return 1 ;;
        *) return 0 ;;
    esac
}

# The dispatcher a general-purpose reader should use — wp_get_stable where it
# is valid, plain wp_get where it is not — so a caller reads a register safely
# without having to know the exclusion list itself.
wp_get_maybe_stable() {
    if wp_reg_is_stable_class "$1"; then
        wp_get_stable "$1"
    else
        wp_get "$1"
    fi
}

# A glitched read here is the expensive one: wittypi-daemon treats "not
# present" as the normal bench case and exits 0, so a single bad read of
# register 0 would silently skip the power sequencing for that whole boot —
# no SYS_UP, no rail cut — and log it as if no controller were fitted.
wp_present() {
    wp_present_id=$(wp_get_stable "$WP_REG_ID") || return 1
    [ "$wp_present_id" = "38" ]   # 0x26
}

# Does this board's firmware implement guaranteed wake (WITTYPI.md layer 3)?
wp_has_guaranteed_wake() {
    wp_hgw_rev=$(wp_get "$WP_REG_FW_REVISION") || return 1
    [ "$wp_hgw_rev" -ge "$WP_MIN_REV_GUARANTEED_WAKE" ]
}

# ── Is the last-resort backstop actually set? ──────────────────────────────
# Shared between a periodic supervisor and an interactive audit tool — the
# one comparison both should make, written once so their verdicts cannot
# drift.
#
# $1 is the EXPECTED raw value (a site's configured guaranteed-wake setting),
# and it is allowed to be EMPTY: site defaults live in the wittypi CLI, not
# here, and duplicating that constant into this file would be a second home
# for it. With no expectation this still enforces the half that is
# load-bearing on ANY board: the register must be readable and must not be
# 0, because 0 means the last-resort wake — the only recovery from a
# shutdown with nothing armed — is switched off.
#
# Prints the raw register value whenever it managed to read one. Returns:
#   0  readable, enabled, and matching $1 (or $1 was empty)
#   1  readable and enabled but NOT the expected value — policy drift
#   2  unreadable — wp_get_stable could not get two agreeing reads
#   3  reads 0 — guaranteed wake is DISABLED
wp_check_guaranteed_wake() {
    wp_cgw_got=$(wp_get_stable "$WP_REG_GUARANTEED_WAKE") || return 2
    printf '%s' "$wp_cgw_got"
    [ "$wp_cgw_got" = "0" ] && return 3
    if [ -n "${1:-}" ] && [ "$wp_cgw_got" != "$1" ]; then
        return 1
    fi
    return 0
}

# ── Arming an alarm — the one write sequence this design allows ────────────
# wp_arm_alarm <sec-base-reg> <epoch-seconds>
#   base 27 = alarm1 (startup), base 32 = alarm2 (shutdown); min/hour/day
#   are base+1..+3. Any other base is refused — this function writes the
#   registers that decide whether the board ever comes back, and a wrong
#   base is not a case to be flexible about.
#
# The invariants (see WITTYPI-ALARM1.md for the full derivation of each):
#
#   * The DAY register is written LAST. The MCU compares all four fields
#     against its RTC once a second; every intermediate state must carry a
#     stale day, which cannot match.
#   * The first write of the sequence clears the firmware's triggered latch
#     (receiveEvent() clears I2C_ALARMx_TRIGGERED on any write inside the
#     block) — so from that instant until the day lands the alarm is "live"
#     with a partial value. Day-last is what makes that window safe.
#   * A TERM/INT mid-write clears day THEN seconds rather than leaving a
#     half-set state — day so nothing can match, seconds as belt to that
#     braces (the one matchable midnight combination WITTYPI-ALARM1.md
#     derives), then exits: systemd's stop is exactly how this dies, and
#     the process was being killed anyway.
#   * The write is READ BACK (wp_get_maybe_stable — alarm registers are
#     stable-class) and backed out day-first on any mismatch. An unverified
#     write here is a board that never wakes.
#
# On success the alarm's "triggered and not yet processed" flag (39/40) is
# cleared too: its consumers are display-only (regs/names, the audit), and
# a flag still waving for the appointment this write just replaced is a
# stale read. The flag write is deliberately NOT read back — it's honesty,
# not safety, and blurring that line would dilute the read-back that
# matters.
#
# No lock is taken here — callers are expected to hold their own lock for
# their whole run (e.g. a systemd unit's flock wrap), matching every other
# writer that touches these registers.
wp_arm_alarm() {
    wp_aa_base=$1
    wp_aa_at=$2
    case "$wp_aa_base" in
        27) wp_aa_flag=$WP_REG_FLAG_ALARM1 ;;
        32) wp_aa_flag=$WP_REG_FLAG_ALARM2 ;;
        *)  wp_log_err "REFUSING: wp_arm_alarm base $wp_aa_base is neither alarm block — nothing written"
            return 1 ;;
    esac
    wp_aa_min=$(( wp_aa_base + 1 ))
    wp_aa_hour=$(( wp_aa_base + 2 ))
    wp_aa_day=$(( wp_aa_base + 3 ))

    # date's zero-padded two-digit fields ARE the BCD once prefixed 0x —
    # -r fallback for non-GNU date.
    wp_aa_d=$(date -u -d "@$wp_aa_at" '+%d' 2>/dev/null || date -u -r "$wp_aa_at" '+%d' 2>/dev/null)
    wp_aa_h=$(date -u -d "@$wp_aa_at" '+%H' 2>/dev/null || date -u -r "$wp_aa_at" '+%H' 2>/dev/null)
    wp_aa_m=$(date -u -d "@$wp_aa_at" '+%M' 2>/dev/null || date -u -r "$wp_aa_at" '+%M' 2>/dev/null)
    wp_aa_s=$(date -u -d "@$wp_aa_at" '+%S' 2>/dev/null || date -u -r "$wp_aa_at" '+%S' 2>/dev/null)
    if [ -z "$wp_aa_d$wp_aa_h$wp_aa_m$wp_aa_s" ]; then
        wp_log_err "REFUSING: cannot render an appointment for register $wp_aa_base — date did not answer"
        return 1
    fi

    trap 'wp_set "$wp_aa_day" 0; wp_set "$wp_aa_base" 0; wp_log "interrupted mid-write — register-$wp_aa_base alarm cleared rather than left half-set"; exit 1' TERM INT

    wp_set "$wp_aa_base" "0x$wp_aa_s"
    wp_set "$wp_aa_min"  "0x$wp_aa_m"
    wp_set "$wp_aa_hour" "0x$wp_aa_h"
    wp_set "$wp_aa_day"  "0x$wp_aa_d"

    trap - TERM INT

    wp_aa_ok=1
    [ "$(wp_get_maybe_stable "$wp_aa_base")" = "$(( 0x$wp_aa_s ))" ] || wp_aa_ok=0
    [ "$(wp_get_maybe_stable "$wp_aa_min")"  = "$(( 0x$wp_aa_m ))" ] || wp_aa_ok=0
    [ "$(wp_get_maybe_stable "$wp_aa_hour")" = "$(( 0x$wp_aa_h ))" ] || wp_aa_ok=0
    [ "$(wp_get_maybe_stable "$wp_aa_day")"  = "$(( 0x$wp_aa_d ))" ] || wp_aa_ok=0
    if [ "$wp_aa_ok" != 1 ]; then
        wp_set "$wp_aa_day" 0
        wp_set "$wp_aa_hour" 0
        wp_set "$wp_aa_min" 0
        wp_set "$wp_aa_base" 0
        wp_log_err "WROTE a register-$wp_aa_base alarm, the read-back did NOT match — cleared rather than trusted"
        return 1
    fi

    wp_set "$wp_aa_flag" 0
    wp_log "armed register-$wp_aa_base alarm for day $wp_aa_d at $wp_aa_h:$wp_aa_m:$wp_aa_s UTC$(wp_utc_note)"
    return 0
}

# ── The board-calibration registry ──────────────────────────────────────────
# Register 37 (RTC_OFFSET) is a measured property of ONE crystal, the ADJ
# registers (24-26) of one ADC. Without a registry, those numbers have
# nowhere durable to live: the HAT's own EEPROM is erased for good by a
# firmware flash (initializeRegisters() does not seed 37), and a single SD
# card's own env file is lost to a card reflash and wrong if that card moves
# to a different board. This registry closes both: the shared image carries
# `${nonarch_libdir}/site/wittypi-boards/<board-id>.env` for every known
# board, and the board picks its own file at run time — so any card on a
# known board applies that board's trims, and version control is the backup
# UUGear otherwise tell you to keep by hand.
#
# The id names the Pi, the trims belong to the HAT. There is nothing unique
# readable over I2C on a Witty Pi 4 (register 0 is a model id, not a
# serial), so the Pi's identity stands in for the bonded Pi+HAT pair. That's
# correct until the day a HAT moves between Pis without its registry entry
# moving with it — rename the file when the hardware moves.

# The Pi's serial from /proc/cpuinfo, leading zeros stripped; the wlan0 MAC
# (colons stripped) when there is no serial to read. WITTYPI_BOARD_ID
# overrides both — the test seam, and the escape hatch for hardware that
# reports neither.
wp_board_id() {
    if [ -n "${WITTYPI_BOARD_ID:-}" ]; then
        printf '%s' "$WITTYPI_BOARD_ID"
        return 0
    fi
    wp_bid=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*//p' \
        "${WP_BOARD_CPUINFO:-/proc/cpuinfo}" 2>/dev/null | sed -n 1p)
    wp_bid=${wp_bid#"${wp_bid%%[!0]*}"}
    if [ -n "$wp_bid" ]; then
        printf '%s' "$wp_bid"
        return 0
    fi
    wp_bid=$(tr -d ':' < "${WP_BOARD_MAC:-/sys/class/net/wlan0/address}" 2>/dev/null)
    if [ -n "$wp_bid" ]; then
        printf '%s' "$wp_bid"
        return 0
    fi
    return 1
}

# Load this board's registry file, if one exists — and apply each WITTYPI_*
# assignment ONLY where the environment does not already have that variable.
#
# The precedence is the contract: a site's own env file (injected by the
# unit's EnvironmentFile before this runs) ALWAYS WINS. The registry is
# factory fact, the site file is deployment intent, and intent overrides
# fact so a bench override keeps working exactly as it always has. "Set but
# empty" counts as set — deliberately blanking a variable is intent too.
#
# Only WITTYPI_[A-Z0-9_]*= lines are honoured; anything else is logged and
# skipped, so a registry file can never smuggle PATH or worse into a
# process that runs as root at boot.
#
# On success sets WP_BOARD_ENV_APPLIED to the applied file's path and
# returns 0; returns 1 (silently) when the board has no id or no file —
# absent calibration is the ordinary case for a board not yet registered,
# not an error.
#
# Must be called in-process, never as `$(wp_load_board_env)` — the whole
# point is the variables it exports, and a command substitution runs it in
# a subshell that keeps them to itself. The path comes back through a
# variable instead of stdout precisely to remove that temptation.
wp_load_board_env() {
    wp_lbe_id=$(wp_board_id) || return 1
    wp_lbe_f="${WITTYPI_BOARD_DIR:-/usr/lib/site/wittypi-boards}/${wp_lbe_id}.env"
    [ -r "$wp_lbe_f" ] || return 1
    while IFS= read -r wp_lbe_line || [ -n "$wp_lbe_line" ]; do
        case "$wp_lbe_line" in
            '#'*|'') continue ;;
            WITTYPI_*=*) ;;
            *) wp_log "board env ${wp_lbe_f}: ignoring non-WITTYPI_ line"
               continue ;;
        esac
        wp_lbe_var=${wp_lbe_line%%=*}
        case "$wp_lbe_var" in
            *[!A-Z0-9_]*)
                wp_log "board env ${wp_lbe_f}: ignoring malformed name '${wp_lbe_var}'"
                continue ;;
        esac
        if eval "[ -z \"\${${wp_lbe_var}+x}\" ]"; then
            wp_lbe_val=${wp_lbe_line#*=}
            eval "${wp_lbe_var}=\$wp_lbe_val; export ${wp_lbe_var}"
        fi
    done < "$wp_lbe_f"
    WP_BOARD_ENV_APPLIED=$wp_lbe_f
    return 0
}

# Telemetry is an integer register and a hundredths register. POSIX shell has no
# floats, so format rather than compute.
wp_read_pair() {
    wp_rp_i=$(wp_get "$1") || return 1
    wp_rp_d=$(wp_get "$2") || return 1
    printf '%d.%02d' "$wp_rp_i" "$wp_rp_d"
}

# ── Leading zeros are OCTAL, and that can corrupt the clock ────────────────
# `date -u +%m` emits ZERO-PADDED fields, and POSIX arithmetic reads a
# leading zero as octal — so 08 and 09 are not "eight" and "nine", they are
# a parse error:
#
#   /usr/libexec/site/wittypi-lib.sh: line NNN: (08: value too great for base
#   RTC set from system clock (UTC): 2026-08-13 22:29:39
#   reads back: 2026-00-13 22:29:39
#
# The conversion then produces nothing, i2cset writes nothing, and the month
# register keeps whatever it held.
#
# This is not obvious in review because 01-07 are VALID octal and evaluate
# to the right decimal value, so the bug is invisible for seven months of
# the year, twenty-two hours of the day and fifty-two seconds of every
# minute. It fires on exactly the values 08 and 09, in every field — and a
# node's only defence against a dead RTC is having written a correct time to
# it.
#
# `10#` would also work and busybox ash accepts it, but it's a bashism that
# dash rejects, and an offline test suite typically runs under the host's
# /bin/sh. Stripping the zeros is portable to both.
wp_dec10() {
    wp_d10_v=${1#"${1%%[!0]*}"}
    [ -n "$wp_d10_v" ] || wp_d10_v=0
    printf '%s' "$wp_d10_v"
}

wp_dec2bcd() {
    wp_d2b_v=$(wp_dec10 "$1")
    printf '0x%02x' "$(( (wp_d2b_v / 10) * 16 + (wp_d2b_v % 10) ))"
}

wp_bcd2dec() {
    wp_b2d_v=$(wp_dec10 "$1")
    echo $(( (wp_b2d_v / 16) * 10 + (wp_b2d_v & 0xF) ))
}

# ── Temperature, from the proxied LM75B ────────────────────────────────────
# A word read, and the byte order is the trap: SMBus word reads are
# little-endian while the LM75B puts its MSB first, so the halves must be
# swapped before anything else. Then >>5 leaves an 11-bit signed value in units
# of 0.125 degrees.
#
# 0.125 is 1/8, so the whole part is v/8 and the fraction is (v%8)*125 — done in
# integers because this shell has no floats and the image has no bc.
wp_temp_c() {
    wp_tc_raw=$(i2cget -y "$WP_BUS" "$WP_ADDR" "$WP_REG_LM75B_TEMP" w 2>/dev/null) || return 1
    case "$wp_tc_raw" in 0x*) ;; *) return 1 ;; esac
    wp_tc_v=$(( ((wp_tc_raw & 0xFF) << 8 | (wp_tc_raw & 0xFF00) >> 8) >> 5 ))
    [ "$wp_tc_v" -ge 1024 ] && wp_tc_v=$(( (wp_tc_v & 0x3FF) - 1024 ))
    wp_tc_sign=''
    if [ "$wp_tc_v" -lt 0 ]; then
        wp_tc_sign='-'
        wp_tc_v=$(( 0 - wp_tc_v ))
    fi
    printf '%s%d.%03d' "$wp_tc_sign" "$(( wp_tc_v / 8 ))" "$(( (wp_tc_v % 8) * 125 ))"
}

# ── The clock, from the proxied PCF85063 ───────────────────────────────────
# Prints ISO-8601. Deliberately NOT via `date -d`: the vendor's script uses GNU
# date's --date parsing, and busybox's date may not support it. Formatting the
# fields directly needs no date(1) at all.
#
# Returns 1 if the year reads 0 — a PCF85063 that has lost power comes up at
# 2000-01-01, and treating that as a valid clock is how a node convinces itself
# it is 25 years in the past.
# One field, checked against what a real clock can hold. A glitched 0xFF read
# becomes bcd2dec(255) = 165, which fails every range below — where without the
# check it would sail through as "month 165" and be handed to date -s.
wp_rtc_field() {
    wp_rf_raw=$(wp_get "$1") || return 1
    wp_rf_v=$(wp_bcd2dec "$wp_rf_raw")
    if [ "$wp_rf_v" -lt "$2" ] || [ "$wp_rf_v" -gt "$3" ]; then
        wp_log "RTC $4 reads $wp_rf_v, outside $2-$3 (register $1 held $wp_rf_raw)"
        return 1
    fi
    printf '%s' "$wp_rf_v"
}

wp_rtc_read() {
    # ── The read can TEAR, and the proxy denies the usual fix ──────────────
    # A driver reads seconds-through-years in ONE burst, which is atomic. The
    # Witty Pi's proxy refuses bulk transfers — `i2cget -y 1 0x08 58 i 3`
    # returns 0x58 0xff 0xff — so this has to be six separate transactions
    # with the clock ticking between them.
    #
    # If a carry lands mid-sequence, the low fields are from before it and the
    # high ones from after: at 10:59:59 -> 11:00:00 you can report 11:59:59, and
    # at a year boundary a date a full YEAR out. So bracket the read with
    # seconds — but what has to be ruled out is a CARRY, not any movement.
    #
    # Requiring seconds to be identical across the two brackets was tried and
    # was too strict — under enough system load (single-core board, network
    # associating, other units starting at boot) six separate forked i2cget
    # calls can take longer than a second, every time, so seconds always
    # moved and the read could never succeed exactly when it was most
    # needed.
    #
    # THE CORRECT INVARIANT: minutes and above can only be stale if seconds
    # WRAPPED (59 -> 00) during the read. If the second reading is >= the first,
    # no carry occurred and every higher field is consistent with it. Only a
    # wrap forces a retry — roughly a 1-in-60 event rather than a certainty.
    #
    # The elapsed-time bound closes the case the comparison alone cannot see: a
    # read so slow that a FULL MINUTE passed would show s2 >= s1 while every
    # higher field had carried underneath it. 30 s is far beyond any plausible
    # read and far below the 60 s that would be ambiguous.
    wp_rr_sec=''
    wp_rr_try=0
    wp_rr_t0=$(date -u +%s 2>/dev/null || echo 0)
    while [ "$wp_rr_try" -lt 6 ]; do
        wp_rr_try=$(( wp_rr_try + 1 ))

        wp_rr_s1=$(wp_get "$WP_REG_RTC_SEC") || return 1
        wp_rr_s1=$(( wp_rr_s1 & 0x7F ))          # bit 7 is the oscillator-stop flag
        wp_rr_sec=$(wp_bcd2dec "$wp_rr_s1")
        if [ "$wp_rr_sec" -gt 59 ]; then
            wp_log "RTC second reads $wp_rr_sec, outside 0-59"
            return 1
        fi

        wp_rr_min=$(wp_rtc_field "$WP_REG_RTC_MIN"   0 59 minute) || return 1
        wp_rr_hr=$(wp_rtc_field  "$WP_REG_RTC_HOUR"  0 23 hour)   || return 1
        wp_rr_day=$(wp_rtc_field "$WP_REG_RTC_DAY"   1 31 day)    || return 1
        wp_rr_mon=$(wp_rtc_field "$WP_REG_RTC_MONTH" 1 12 month)  || return 1
        wp_rr_yr=$(wp_rtc_field  "$WP_REG_RTC_YEAR"  0 99 year)   || return 1

        wp_rr_s2=$(wp_get "$WP_REG_RTC_SEC") || return 1
        wp_rr_s2=$(( wp_rr_s2 & 0x7F ))
        wp_rr_sec2=$(wp_bcd2dec "$wp_rr_s2")

        # No wrap => no carry into minutes => the higher fields are coherent.
        # Report the LATER seconds: it is the one that matches the moment the
        # higher fields were still valid at, and it is never more than the read
        # window old.
        if [ "$wp_rr_sec2" -ge "$wp_rr_sec" ]; then
            wp_rr_now=$(date -u +%s 2>/dev/null || echo 0)
            if [ "$wp_rr_t0" -gt 0 ] && [ "$((wp_rr_now - wp_rr_t0))" -ge 30 ]; then
                wp_log "RTC read took $((wp_rr_now - wp_rr_t0))s — too slow to rule out a minute carry"
                return 1
            fi
            wp_rr_sec="$wp_rr_sec2"
            break
        fi
        wp_rr_sec=''
    done

    # Six WRAPS in a row is not a slow shell — a wrap is a 1-in-60 event, so six
    # consecutive ones means something is wrong with the bus, not with timing.
    # A refusal costs the caller a clock; a torn timestamp costs the schedule,
    # because the next wake is computed from whatever this returns.
    if [ -z "$wp_rr_sec" ]; then
        wp_log "RTC read straddled a MINUTE BOUNDARY six times — refusing to report a torn timestamp"
        return 1
    fi

    printf '%04d-%02d-%02d %02d:%02d:%02d' \
        "$(( 2000 + wp_rr_yr ))" "$wp_rr_mon" "$wp_rr_day" \
        "$wp_rr_hr" "$wp_rr_min" "$wp_rr_sec"

    [ "$wp_rr_yr" -eq 0 ] && return 1
    return 0
}

# ── A second opinion, for a glitch wp_rtc_read cannot see ──────────────────
# wp_rtc_read already rejects a TORN read (a carry mid-multi-register-read,
# via its own seconds bracket) and an OUT-OF-RANGE field. Neither catches a
# glitch that lands ON a valid value — the same 0x00-then-0x01 register-17
# glitch discussed above, applied to a clock field instead: in range both
# times, order 0.1% of reads. An hour field glitching the same way at boot
# would be silently believed and used to compute every wake this power-on
# schedules.
#
# So: read again, and require the SAME clock — allowing for the seconds that
# elapse between two honest reads — before trusting it. Two consecutive reads
# that happen to share the same one-off glitch is overwhelmingly unlikely;
# two that disagree keep reading, up to a bound, rather than picking either on
# a hunch.
#
# This catches a transient misread. It cannot catch a consistently wrong
# clock — an RTC that is, say, twelve hours off but ticking forward
# correctly at the wrong offset would pass this check every time: every read
# agrees with every other, because the RTC itself, not any one read of it,
# is wrong. That failure needs a different check (a plausibility bound
# against something the RTC did not itself produce) and doesn't have one
# here.
WP_RTC_CONFIRM_MAX="${WP_RTC_CONFIRM_MAX:-5}"
WP_RTC_CONFIRM_SLOP="${WP_RTC_CONFIRM_SLOP:-5}"

wp_rtc_read_confirmed() {
    wp_rc_prev=''
    wp_rc_prev_ts=''
    wp_rc_n=0
    while [ "$wp_rc_n" -lt "$WP_RTC_CONFIRM_MAX" ]; do
        wp_rc_n=$(( wp_rc_n + 1 ))
        if ! wp_rc_cur=$(wp_rtc_read); then
            # "Year reads 00" is not a glitch to retry past. wp_rtc_read
            # returns 1 with output for exactly one reason otherwise: the
            # coin cell is flat and the RTC is at its epoch. That's a
            # stable, structural fact — re-reading it five times would just
            # confirm 2000-01-01 five times and hide the real fault behind
            # this function's job, which is catching NOISE. Propagate it
            # as-is and let the caller's existing lost-power handling do
            # its job.
            if [ -n "$wp_rc_cur" ]; then
                printf '%s' "$wp_rc_cur"
                return 1
            fi
            wp_rc_prev=''; wp_rc_prev_ts=''
            continue
        fi
        wp_rc_cur_ts=$(date -u -d "$wp_rc_cur" +%s 2>/dev/null) || \
            { wp_rc_prev=''; wp_rc_prev_ts=''; continue; }

        if [ -n "$wp_rc_prev_ts" ]; then
            wp_rc_delta=$(( wp_rc_cur_ts - wp_rc_prev_ts ))
            # Never negative: two honest reads only ever move forward — a
            # negative delta IS the disagreement, not a rounding artefact.
            # Bounded above by WP_RTC_CONFIRM_SLOP so a real gap (this
            # process descheduled, wp_rtc_read's own tear-retry running long)
            # does not get accepted as "the same moment read twice".
            if [ "$wp_rc_delta" -ge 0 ] && [ "$wp_rc_delta" -le "$WP_RTC_CONFIRM_SLOP" ]; then
                printf '%s' "$wp_rc_cur"
                return 0
            fi
            wp_log "RTC reads disagree: $wp_rc_prev -> $wp_rc_cur (${wp_rc_delta}s) — retry $wp_rc_n/$WP_RTC_CONFIRM_MAX"
        fi
        wp_rc_prev="$wp_rc_cur"
        wp_rc_prev_ts="$wp_rc_cur_ts"
    done

    wp_log_err "RTC could not be confirmed across $WP_RTC_CONFIRM_MAX reads — no two consecutive reads agreed"
    return 1
}

# ── GPIO ───────────────────────────────────────────────────────────────────
# libgpiod v2, NOT wiringPi and NOT sysfs. Verified against the v2 tool
# sources rather than remembered: v2 renamed and re-scoped most of v1's
# flags, so a v1-shaped command line fails in ways that read like a wiring
# fault.
#
# The chip is resolved by LABEL, not by assuming gpiochip0. On BCM2835 the
# pinctrl chip is normally gpiochip0, but that ordering is a property of probe
# order rather than a guarantee, and picking the wrong chip would drive some
# other peripheral's lines — the failure would look like the Witty Pi ignoring
# us while something else misbehaved.
wp_gpiochip() {
    if [ -n "${WITTYPI_GPIOCHIP:-}" ]; then
        printf '%s' "$WITTYPI_GPIOCHIP"
        return 0
    fi
    wp_gc_found=$(gpiodetect 2>/dev/null | awk '/pinctrl-bcm/ { print $1; exit }')
    if [ -n "$wp_gc_found" ]; then
        printf '%s' "$wp_gc_found"
        return 0
    fi
    return 1
}

# Read the halt line. Pull-up because the MCU pulls it DOWN to request
# shutdown; without bias a floating line reads as a spurious request.
#
# ── --numeric is not optional ───────────────────────────────────────────────
# libgpiod v2's gpioget does NOT print 0/1 by default the way v1 did — it
# prints
#
#     "4"=active
#
# so a caller doing `[ "$(wp_halt_level ...)" = "1" ]` without --numeric
# would be false forever. A daemon's stability loop that waits for five
# consecutive HIGH reads before arming would then never exit — spinning
# until the battery died, having never sent the SYS_UP handshake, which
# means the MCU never sets systemIsUp, never watches TXD, and the rail is
# never cut. The daemon would also never arm on the halt GPIO, so a
# shutdown REQUEST would be ignored too — both halves of the power
# sequencing silently absent, on a board whose unit reports `active`.
#
# `sed 's/.*=//'` normalises both the bare `1` this flag produces and any
# `"4"=1` form, so a future formatting change degrades to a wrong-but-visible
# value rather than to a hang.
wp_halt_level() {
    gpioget --numeric -b pull-up -c "$1" "$WP_HALT_PIN" 2>/dev/null | sed 's/.*=//'
}
