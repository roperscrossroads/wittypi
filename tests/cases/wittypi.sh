#!/bin/sh
# The Witty Pi 4 power sequencing, and the one property that matters most.
#
# WHAT THIS PROTECTS
# ------------------
# The Witty Pi does have a timeout-based forced power cut (see WITTYPI.md,
# "The three facts that shape everything") — the timer ISR calls cutPower()
# itself, and on the scheduled path the rail drops POWER_CUT_DELAY after the
# request regardless of whether a gate ever returns.
#
# THE ASSERTIONS BELOW ARE STILL WORTH HAVING — the conclusion survived its
# premise, which is worth stating rather than quietly rewriting:
#
#   * a gate that cannot return still costs a DIRTY SHUTDOWN every cycle: the
#     rail is cut at 15 s with Linux still running and /data mounted rw.
#   * the LINUX-INITIATED path is genuinely different — there turnOffFromTXD is
#     set, and TXD returning high cancels the cut and is read as a reboot. A
#     hang there really can leave the rail up.
#   * and a gate that terminates is the only way the /data miss-record is ever
#     written, since the rail will not wait for it.
#
# What the assertions do NOT check is that the bound is small enough relative
# to your own POWER_CUT_DELAY — a test that pins the grace below that budget
# belongs here once you've chosen both values for your deployment.
#
# These assertions exist because that failure is invisible in review: a wait
# loop that is wrong looks exactly like one that is right.
#
# WHY THE sleep STUB ADVANCES THE CLOCK
# -------------------------------------
# The gate reads $PROC_UPTIME, which in a fixture is a static file — so a naive
# test of "does it terminate" would hang forever, which is also precisely the
# production bug being tested for. Stubbing sleep so that it MOVES the fixture
# clock models the one thing that actually happens on the node, makes the test
# take milliseconds instead of two minutes, and means a gate that stopped
# consulting the clock would spin here rather than pass.
#
# That stub is GENERATED shell, so its $(...) and ${1:-1} must survive to the
# stub rather than expanding here — the single quotes are the point (SC2016).
# The directive has to precede the first command to be file-scoped and carry no
# trailing prose, exactly as radio-on-demand.sh notes.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

GATE="$RPI_UNITS_DIR/wittypi-before-shutdown"
DAEMON="$RPI_UNITS_DIR/wittypi-daemon"
LIB="$RPI_UNITS_DIR/wittypi-lib.sh"

# sleep <n> advances the fixture's /proc/uptime by n seconds.
stub_ticking_sleep() {
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/sleep"\n' "$1"
        printf 'cur=$(cut -d" " -f1 "%s/proc/uptime" | cut -d. -f1)\n' "$1"
        printf 'printf "%%s.00 2000.00\\n" "$(( cur + ${1:-1} ))" > "%s/proc/uptime"\n' "$1"
    } > "$1/bin/sleep"
    chmod +x "$1/bin/sleep"
}

describe "the shipped pieces exist"
assert_file_exists "$GATE"   "wittypi-before-shutdown"
assert_file_exists "$DAEMON" "wittypi-daemon"
assert_file_exists "$LIB"    "wittypi-lib.sh"

# ── The gate returns when the slot is already good ─────────────────────────
describe "an already-good slot is not waited for"
F=$(fixture_new)
stub_ticking_sleep "$F"
stub "$F" systemctl "exit 0"          # boot-complete.target is active
stub "$F" rauc "exit 0"
export WITTYPI_REASON=2               # ALARM2, the ordinary scheduled shutdown
export WITTYPI_MARKGOOD_GRACE=120
run_rpi_unit "$F" wittypi-before-shutdown
assert_eq "0" "$RUN_RC" "returns success"
assert_contains "$RUN_OUT" "already marked good" "recognises the slot is good"
if [ -z "$(stub_log "$F" sleep)" ]; then
    ok "it did not sleep at all"
else
    notok "it did not sleep at all" \
        "a good slot must cost zero shutdown latency; sleeping here eats the awake window"
fi
fixture_rm "$F"

# ── Urgent reasons are not gated AT ALL ────────────────────────────────────
# The most important assertion in this file. Low voltage means the controller
# is protecting the battery; waiting on RAUC bookkeeping while it drains is the
# wrong trade, and the reason register is the only way to tell.
describe "voltage and thermal shutdowns are never delayed"
for reason in 4 6 7; do
    F=$(fixture_new)
    stub_ticking_sleep "$F"
    stub "$F" systemctl "exit 1"      # NOT good — a gating build would wait
    stub "$F" rauc "exit 1"
    export WITTYPI_REASON="$reason"
    export WITTYPI_MARKGOOD_GRACE=120
    run_rpi_unit "$F" wittypi-before-shutdown
    assert_eq "0" "$RUN_RC" "reason $reason returns success"
    if [ -z "$(stub_log "$F" sleep)" ]; then
        ok "reason $reason did not wait"
    else
        notok "reason $reason did not wait" \
            "gating an urgent shutdown defeats the protection it exists to serve"
    fi
    fixture_rm "$F"
done

# ── The gate is BOUNDED ────────────────────────────────────────────────────
describe "a slot that never goes good still releases the shutdown"
F=$(fixture_new)
stub_ticking_sleep "$F"
stub "$F" systemctl "exit 1"          # never becomes good
stub "$F" rauc "exit 1"
export WITTYPI_REASON=2
export WITTYPI_MARKGOOD_GRACE=20
set_uptime "$F" 1000
run_rpi_unit "$F" wittypi-before-shutdown
assert_eq "0" "$RUN_RC" "returns success even though mark-good never happened"
assert_contains "$RUN_OUT" "grace expired" "says so plainly"
assert_file_exists "$F/data/wittypi-markgood-missed" "the miss is recorded to /data"

# The deadline must be computed ONCE, from the clock, and be unextendable.
# 20 s of grace at 5 s a sleep is 4 sleeps; anything much larger means the
# deadline is being recomputed inside the loop.
sleeps=$(stub_log "$F" sleep | wc -l | tr -d ' ')
if [ "$sleeps" -le 6 ]; then
    ok "it waited a bounded number of times ($sleeps)"
else
    notok "it waited a bounded number of times ($sleeps)" \
        "the deadline is being extended inside the loop — this is the ext-power-controller bug"
fi
fixture_rm "$F"

describe "the deadline comes from a monotonic clock, not the wall clock"
# The Witty Pi writes RTC time into the system clock at startup and NTP may
# step it again during this very window. A date(1)-based deadline could be
# pushed AWAY, which is the unbounded wait this design exists to prevent.
gate_body=$(grep -vE '^\s*#' "$GATE")
if printf '%s' "$gate_body" | grep -q 'PROC_UPTIME\|/proc/uptime'; then
    ok "it reads /proc/uptime"
else
    notok "it reads /proc/uptime" "a wall-clock deadline can be stepped away from"
fi
if printf '%s' "$gate_body" | grep -qE 'date .*\+%s|date \+%s'; then
    notok "it does not compute the deadline from date(1)" \
        "date +%s is wall clock and moves when NTP steps"
else
    ok "it does not compute the deadline from date(1)"
fi

# ── SYS_UP must be one invocation ──────────────────────────────────────────
describe "the SYS_UP pulse train is a single gpioset"
# libgpiod releases a line when the holding process exits, so four sequential
# gpioset calls would drop GPIO-17 between every pulse and emit a waveform the
# MCU may never register. The recipe enforces this at build time too; asserting
# it here as well is deliberate, because the recipe guard only runs on a build
# host with bitbake and this file runs everywhere.
daemon_body=$(grep -vE '^\s*#' "$DAEMON")
# grep -o, NOT grep -c. -c counts matching LINES, so two gpioset calls joined by
# a semicolon on one line counted as 1 and the assertion passed — caught by
# mutation-testing this very check, which is the only reason it is right now.
gpioset_calls=$(printf '%s\n' "$daemon_body" | grep -o 'gpioset' | wc -l | tr -d ' ')
assert_eq "1" "$gpioset_calls" "exactly one gpioset call"
if printf '%s' "$daemon_body" | grep -qE '\-t [0-9]+ms|--toggle'; then
    ok "it uses --toggle to make the train"
else
    notok "it uses --toggle to make the train" \
        "a single set cannot produce 1-0-1-0; without toggle the MCU sees one edge"
fi

describe "the daemon always reaches poweroff"
if printf '%s' "$daemon_body" | grep -q 'systemctl poweroff'; then
    ok "it powers off"
else
    notok "it powers off" "if the daemon never powers off, TXD never drops and the rail stays up"
fi
# The gate is allowed to fail. It is not allowed to prevent the poweroff.
if printf '%s' "$daemon_body" | grep -q 'WP_GATE" ||'; then
    ok "a failing gate does not stop the poweroff"
else
    notok "a failing gate does not stop the poweroff" \
        "set -e or an unguarded call would let the gate strand the rail up"
fi

# ── Register numbers must match the vendor firmware ────────────────────────
# The numbers in wittypi-lib.sh were read out of WittyPi4.ino. If the vendored
# tree is present, prove they still agree rather than trusting a transcription
# — a wrong register number is a silent write to the wrong setting.
#
# witty/ is gitignored (it carries its own .git and 22 MB of datasheets), so
# this is skipped rather than failed when it is absent. A skip is honest; a
# pass would not be.
describe "register numbers agree with the vendored firmware source"
INO="$LAYER_DIR/witty/Witty-Pi-4/Firmware/WittyPi4/WittyPi4.ino"
if [ ! -f "$INO" ]; then
    ok "SKIPPED — vendored firmware absent (clone into witty/ to enable)"
else
    check_reg() {
        want=$(grep -oE "^#define $1 +[0-9]+" "$INO" | awk '{print $3}')
        got=$(grep -oE "^$2=[0-9]+" "$LIB" | cut -d= -f2)
        if [ -n "$want" ] && [ "$want" = "$got" ]; then
            ok "$2 = $got matches $1"
        else
            notok "$2 = $got matches $1" \
                "firmware says '$want' — a wrong register number writes to the wrong setting"
        fi
    }
    check_reg I2C_ACTION_REASON       WP_REG_ACTION_REASON
    check_reg I2C_FW_REVISION         WP_REG_FW_REVISION
    check_reg I2C_CONF_POWER_CUT_DELAY WP_REG_POWER_CUT_DELAY
    check_reg I2C_CONF_LOW_VOLTAGE    WP_REG_LOW_VOLTAGE
    check_reg I2C_CONF_RECOVERY_VOLTAGE WP_REG_RECOVERY_VOLTAGE
    check_reg I2C_CONF_GUARANTEED_WAKE WP_REG_GUARANTEED_WAKE
    check_reg I2C_CONF_DEFAULT_ON     WP_REG_DEFAULT_ON

    # And the reason codes the gate branches on.
    for pair in "REASON_LOW_VOLTAGE:WP_REASON_LOW_VOLTAGE" \
                "REASON_OVER_TEMPERATURE:WP_REASON_OVER_TEMPERATURE" \
                "REASON_BELOW_TEMPERATURE:WP_REASON_BELOW_TEMPERATURE" \
                "REASON_ALARM2:WP_REASON_ALARM2"; do
        check_reg "${pair%%:*}" "${pair##*:}"
    done
fi

# ── BCD conversion: the octal trap ─────────────────────────────────────────
# date(1) emits ZERO-PADDED fields and POSIX arithmetic reads a leading zero as
# octal, so "08" and "09" are a parse error rather than eight and nine — a
# real month write like this can produce nothing and leave the RTC reading a
# corrupt date.
#
# Why review did not catch it: 01-07 are valid octal AND evaluate to the right
# decimal value, so the conversion is correct for seven months of the year,
# twenty-two hours of the day, and fifty-two seconds of every minute. It is
# wrong for exactly two values per field — which is also why a spot-check with
# a handful of numbers would have passed.
#
# So this sweeps the WHOLE domain rather than sampling it. These are pure
# functions over 0-99; there is no excuse for testing them by example.
describe "dec<->BCD survives zero-padded input (the octal trap)"

CLI="$RPI_UNITS_DIR/wittypi"

# Call a library function in a subshell, so its constants cannot leak into the
# rest of this file. One source site, so one SC1090 directive rather than six.
# shellcheck source=/dev/null
wp_lib_call() { ( . "$LIB"; "$@" ) 2>&1; }

# wp_volts_to_reg lives in the CLI, not the library, and needs the library
# under it. Lifting the function out beats duplicating it here: a copy would go
# on passing after the original changed.
# shellcheck source=/dev/null
wp_volts_call() {
    ( . "$LIB"
      eval "$(sed -n '/^wp_volts_to_reg()/,/^}/p' "$CLI")"
      wp_volts_to_reg "$1" ) 2>&1
}

bcd_rt_bad=''
bcd_pad_bad=''
i=0
while [ "$i" -le 99 ]; do
    enc=$(wp_lib_call wp_dec2bcd "$i")
    dec=$(wp_lib_call wp_bcd2dec "$(( enc ))")
    [ "$dec" = "$i" ] || bcd_rt_bad="$bcd_rt_bad $i->$enc->$dec"

    # The same value as date(1) would hand it over: %02d.
    pad=$(printf '%02d' "$i")
    encpad=$(wp_lib_call wp_dec2bcd "$pad")
    [ "$encpad" = "$enc" ] || bcd_pad_bad="$bcd_pad_bad $pad(=$encpad,want $enc)"
    i=$(( i + 1 ))
done

if [ -z "$bcd_rt_bad" ]; then
    ok "every value 0-99 round-trips dec->BCD->dec"
else
    notok "every value 0-99 round-trips dec->BCD->dec" "failed:$bcd_rt_bad"
fi
if [ -z "$bcd_pad_bad" ]; then
    ok "zero-padded input encodes identically to unpadded (date(1) pads)"
else
    notok "zero-padded input encodes identically to unpadded (date(1) pads)" \
        "the octal trap is back — these are the values date(1) will feed it:$bcd_pad_bad"
fi

# The two values that actually broke, named explicitly so a regression reads as
# itself in the output rather than as one entry in a sweep.
assert_eq "0x08" "$(wp_lib_call wp_dec2bcd 08)" "August encodes as 0x08, not a parse error"
assert_eq "0x09" "$(wp_lib_call wp_dec2bcd 09)" "September encodes as 0x09, not a parse error"

describe "voltage thresholds survive a zero-padded integer part"
assert_eq "96"  "$(wp_volts_call 09.6)" "09.6V -> 96 (a padded 3S LiFePO4 cutoff)"
assert_eq "115" "$(wp_volts_call 11.5)" "11.5V -> 115 (the unpadded form still works)"

# ── The read-back must be COMPARED, not printed ────────────────────────────
# rtc-write printed its read-back and exited 0 regardless, so it announced
# success above an impossible date. Same shape as the discarded build log and
# the mutation harness that selected a row of dashes: a plausible-looking
# result standing in for a check that never happened.
#
# A shape assertion here would be worthless: grepping the rtc-write body for
# "exit 1" and a "!=" mentioning the read-back variable would still pass a
# mutation that gutted the comparison (`wp_rc=1` -> `:`, `if [ rc -ne 0 ]` ->
# `if false`), because both strings would still sit in the source doing
# nothing. A shape assertion cannot tell running code from decoration.
# So this drives the real script against stubbed i2c tools and checks what it
# DOES.
stub_i2c() {
    mkdir -p "$1/regs"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/i2cset"\n' "$1"
        # WP_DROP_REG models the real failure: a write that silently does not
        # take, which is what the octal parse error produced.
        printf '[ "$4" = "${WP_DROP_REG:-none}" ] && exit 0\n'
        printf 'printf "%%s\\n" "$5" > "%s/regs/$4"\n' "$1"
    } > "$1/bin/i2cset"
    {
        printf '#!/bin/sh\n'
        printf '[ "$4" = "0" ] && { echo 0x26; exit 0; }\n'   # firmware id, so wp_present passes
        printf 'if [ -f "%s/regs/$4" ]; then cat "%s/regs/$4"; else echo 0x00; fi\n' "$1" "$1"
    } > "$1/bin/i2cget"
    # A fixed clock, so the test exercises AUGUST every day of the year rather
    # than only during August. This is the input that broke the node.
    {
        printf '#!/bin/sh\n'
        printf 'echo "26 08 13 22 29 39"\n'
    } > "$1/bin/date"
    chmod +x "$1/bin/i2cset" "$1/bin/i2cget" "$1/bin/date"
}

describe "rtc-write writes a correct August and says so"
F=$(fixture_new)
stub_i2c "$F"
unset WP_DROP_REG
run_rpi_unit "$F" wittypi rtc-write
assert_eq "0" "$RUN_RC" "a clean write succeeds"
assert_eq "0x08" "$(cat "$F/regs/63" 2>/dev/null)" "month 08 reaches register 63 as BCD 0x08"
assert_contains "$RUN_OUT" "2026-08-13 22:29:39" "reads back the date it was given"
fixture_rm "$F"

describe "rtc-write FAILS when a field does not take"
F=$(fixture_new)
stub_i2c "$F"
export WP_DROP_REG=63                 # the month — exactly what the octal bug lost
run_rpi_unit "$F" wittypi rtc-write
unset WP_DROP_REG
assert_eq "1" "$RUN_RC" "a dropped field exits non-zero"
assert_contains "$RUN_OUT" "FAILED" "names the field that did not take"
assert_not_contains "$RUN_OUT" "all fields verified" \
    "it must not claim success — announcing 2026-00-13 as OK is the original defect"
fixture_rm "$F"

# ── rtc-write must not PERSIST a clock the board never had ─────────────────
# This has happened for real, on the first boot of an image that added the
# unit:
#
#   wittypi[633]: RTC set from system clock (UTC), all fields verified:
#                 2026-03-13 15:35:37
#
# Two seconds into boot, with NTPSynchronized=no. wittypi-rtc-save.service had
# Requires=time-sync.target, and that target is PASSIVE — reached whenever
# nothing delays it, and the thing that delays it (systemd-time-wait-sync) is
# disabled in this image. So systemd's compiled-in floor was written into the
# RTC and verified field by field.
#
# WORSE THAN NOT WRITING: the node then comes up at the floor CONFIDENTLY, and
# the "year reads 00" tell that says the coin cell is flat is destroyed.
#
# The unit now gates on /run/systemd/timesync/synchronized. This is the second
# line of defence, and the one that matters for a human: the command is meant
# to be typed, and typing it on an unsynced node does the same damage.
stub_i2c_epoch() {
    stub_i2c "$1"
    # The real script asks for fields AND, in the new guard, for +%s. One stub,
    # two answers — a fixed clock either way so the test does not depend on
    # today's date.
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in *%%s*) echo "%s" ;; *) echo "26 08 13 22 29 39" ;; esac\n' "$2"
    } > "$1/bin/date"
    chmod +x "$1/bin/date"
}

describe "rtc-write REFUSES a system clock older than the image"
F=$(fixture_new)
# Clock at 2026-03-13 (the measured systemd floor); build epoch 2026-08-01.
stub_i2c_epoch "$F" 1773360000
echo 1785556800 > "$F/build-epoch"
BUILD_EPOCH_FILE="$F/build-epoch"; export BUILD_EPOCH_FILE
run_rpi_unit "$F" wittypi rtc-write
assert_eq "1" "$RUN_RC" "exits non-zero"
assert_contains "$RUN_OUT" "BEFORE this image was built" "says why"
assert_contains "$RUN_OUT" "destroy the" "and what it would cost"
assert_not_contains "$RUN_OUT" "all fields verified" "it must not claim it wrote anything"
assert_eq "" "$(cat "$F/regs/63" 2>/dev/null)" "and no register was actually written"
fixture_rm "$F"

describe "...but a plausible clock still writes"
# The half that makes the test above mean something: if both cases refused, the
# guard would be indistinguishable from breaking rtc-write outright.
F=$(fixture_new)
stub_i2c_epoch "$F" 1786000000          # after the build epoch
echo 1785556800 > "$F/build-epoch"
BUILD_EPOCH_FILE="$F/build-epoch"
run_rpi_unit "$F" wittypi rtc-write
assert_eq "0" "$RUN_RC" "a sane clock succeeds"
assert_contains "$RUN_OUT" "all fields verified" "and reports the verified write"
fixture_rm "$F"

describe "...and the refusal can be overridden deliberately"
F=$(fixture_new)
stub_i2c_epoch "$F" 1773360000
echo 1785556800 > "$F/build-epoch"
BUILD_EPOCH_FILE="$F/build-epoch"
export WITTYPI_FORCE_RTC_WRITE=1
run_rpi_unit "$F" wittypi rtc-write
unset WITTYPI_FORCE_RTC_WRITE
assert_eq "0" "$RUN_RC" "the override writes"
assert_contains "$RUN_OUT" "writing anyway" "and says it is doing so"
fixture_rm "$F"
unset BUILD_EPOCH_FILE

describe "an unreadable build-epoch does not block rtc-write"
# Cannot-tell must not become cannot-write: a slot from an older bundle has no
# such file, and rtc-write is how a node keeps time across a power cut.
F=$(fixture_new)
stub_i2c_epoch "$F" 1773360000
BUILD_EPOCH_FILE="$F/no-such-file"; export BUILD_EPOCH_FILE
run_rpi_unit "$F" wittypi rtc-write
assert_eq "0" "$RUN_RC" "writes when the floor is unknown"
fixture_rm "$F"
unset BUILD_EPOCH_FILE

# ── The halt line must be read as a NUMBER ─────────────────────────────────
# libgpiod v2's gpioget does not print 0/1 the way v1 did — it prints
#
#     "4"=active
#
# so `[ "$(wp_halt_level ...)" = "1" ]` was false forever and the daemon's
# settle loop never exited. On the node it had spun ~900 times over fifteen
# minutes with the unit reporting `active` and the journal showing nothing
# after the telemetry line.
#
# WHAT IT COST, precisely: the daemon never reached the SYS_UP pulse, so the
# firmware never set systemIsUp; without systemIsUp it never sets listenToTxd
# (WittyPi4.ino:758), so TXD dropping is not read as a shutdown and THE RAIL IS
# NEVER CUT. It also never armed on GPIO-4, so a shutdown request would have
# been ignored. Both halves of the power sequencing were absent.
#
# Nothing offline could have caught it, because nothing offline could run this
# script at all — /dev/i2c-1 does not exist on a build host and the daemon
# exits before anything else. WITTYPI_I2C_DEV closes that, which is why these
# assertions can exist.
stub_gpio() {
    {
        printf '#!/bin/sh\n'
        printf 'echo "gpiochip0 [pinctrl-bcm2835] (54 lines)"\n'
    } > "$1/bin/gpiodetect"
    # The REAL libgpiod v2 output shapes, both of them.
    {
        printf '#!/bin/sh\n'
        printf 'lvl=${WP_STUB_LEVEL:-1}\n'
        printf 'for a in "$@"; do\n'
        printf '  [ "$a" = "--numeric" ] && { echo "$lvl"; exit 0; }\n'
        printf 'done\n'
        printf '[ "$lvl" = "1" ] && echo \x27"4"=active\x27 || echo \x27"4"=inactive\x27\n'
    } > "$1/bin/gpioget"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/gpioset"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/gpiomon"   # as if the edge fired
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/gpioinfo"  # line unclaimed
    {
        printf '#!/bin/sh\n'
        printf 'case "$4" in 0) echo 0x26;; 12) echo 0x07;; 11) echo 0x0a;; *) echo 0x00;; esac\n'
    } > "$1/bin/i2cget"
    chmod +x "$1/bin/gpiodetect" "$1/bin/gpioget" "$1/bin/gpioset" \
             "$1/bin/gpiomon" "$1/bin/gpioinfo" "$1/bin/i2cget"
    touch "$1/dev-i2c"
}

describe "wp_halt_level reads libgpiod v2 output as a number"
F=$(fixture_new)
stub_gpio "$F"
assert_eq "1" "$(PATH="$F/bin:$PATH" WP_STUB_LEVEL=1 sh -c ". '$LIB'; wp_halt_level gpiochip0")" \
    "a HIGH line reads 1, not '\"4\"=active'"
assert_eq "0" "$(PATH="$F/bin:$PATH" WP_STUB_LEVEL=0 sh -c ". '$LIB'; wp_halt_level gpiochip0")" \
    "a LOW line reads 0, not '\"4\"=inactive'"
fixture_rm "$F"

describe "the daemon arms without complaint when the halt line is healthy"
F=$(fixture_new)
stub_gpio "$F"
stub_ticking_sleep "$F"
stub "$F" systemctl "exit 0"
export WITTYPI_I2C_DEV="$F/dev-i2c"
export WITTYPI_GATE="$F/no-such-gate"
export WP_STUB_LEVEL=1
run_rpi_unit "$F" wittypi-daemon
assert_contains "$RUN_OUT" "signalling SYS_UP" "it reaches the SYS_UP pulse"
assert_contains "$RUN_OUT" "armed" "it arms on the halt line"
# THE ASSERTION THAT CATCHES THE BUG. With the settle bounded, a wp_halt_level
# that never returns "1" no longer hangs — it warns and proceeds. So "did it
# arm" is no longer sufficient evidence that the line is being read correctly,
# and only the ABSENCE of the warning distinguishes a working read from a
# broken one that timed out.
assert_not_contains "$RUN_OUT" "did not read high" \
    "a healthy line must settle on its own; a warning here means the level is being misparsed"
fixture_rm "$F"

describe "a halt line stuck low does not hang the daemon"
# The failure this bounds is not hypothetical — it is the one above. An
# unbounded settle turns any misread into a held rail and a flat battery, which
# on a solar node is unrecoverable until the sun comes back.
F=$(fixture_new)
stub_gpio "$F"
stub_ticking_sleep "$F"
stub "$F" systemctl "exit 0"
export WITTYPI_I2C_DEV="$F/dev-i2c"
export WITTYPI_GATE="$F/no-such-gate"
export WP_STUB_LEVEL=0
export WITTYPI_HALT_SETTLE_SEC=15
run_rpi_unit "$F" wittypi-daemon
unset WP_STUB_LEVEL
assert_contains "$RUN_OUT" "did not read high" "it says the line never settled"
assert_contains "$RUN_OUT" "signalling SYS_UP" \
    "it STILL sends SYS_UP — without it the MCU never watches TXD and cannot cut the rail"
settle_sleeps=$(stub_log "$F" sleep | wc -l | tr -d ' ')
if [ "$settle_sleeps" -le 20 ]; then
    ok "the settle is bounded ($settle_sleeps sleeps)"
else
    notok "the settle is bounded ($settle_sleeps sleeps)" \
        "an unbounded settle can spin hundreds of times on real hardware"
fi
fixture_rm "$F"
unset WITTYPI_I2C_DEV WITTYPI_GATE WITTYPI_HALT_SETTLE_SEC

# ── The policy: what configure actually writes ─────────────────────────────
# A register-by-register read of a real board has found it holding most of
# its specified rows unapplied — with the rows that were right being right
# only because they're also the factory defaults. The specification existed;
# nothing carried it to the hardware.
#
# These drive the real script against the stubbed bus and assert on registers,
# not on the source. A shape assertion cannot tell a policy that is applied
# from one that is merely written down, which is the whole failure here.

# A board that answers as firmware revision 7, so layer 3 is in the policy.
stub_board_rev7() { printf '0x07\n' > "$1/regs/12"; }

# Read a register the way the firmware would — as a NUMBER.
#
# Two reasons this cannot be a `cat`. A register the stub was never asked to
# write has no file and reads back as 0 through i2cget — which is also what a
# policy row of 0 looks like once configure has correctly decided not to write
# it, so `cat` reports an empty string for a register that is in fact right.
# And seeded values are hex ("0x01") where configure writes decimal ("150"), so
# one value has two spellings. Comparing the text asserts on the stub's
# bookkeeping rather than on the board's state.
reg_dec() {
    if [ -f "$1/regs/$2" ]; then echo $(( $(cat "$1/regs/$2") )); else echo 0; fi
}

describe "configure applies the WHOLE table, not the five registers it used to"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
unset WP_DROP_REG
export WITTYPI_TOPOLOGY=vin3s
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "a clean apply succeeds"
# The rows the old configure had no path to at all.
# 47 is 10, not the 254 this once asserted: the firmware computes
# delay(reg * 1000) in a 16-bit int, so 254 wrapped to ~49.7 days and DEFAULT_ON
# never fired. See the overflow cases below.
for pair in "20:0" "23:0" "41:0" "45:1" "46:70" "47:10" "48:0"; do
    reg=${pair%%:*}; want=${pair##*:}
    assert_eq "$want" "$(reg_dec "$F" "$reg")" \
        "register $reg reaches the board as $want"
done
# And the ones it did.
assert_eq "1"   "$(reg_dec "$F" 17)" "17 default-on"
assert_eq "250" "$(reg_dec "$F" 21)" "21 power-cut delay is 25s — the ceiling, and not the vendor 7"
# 26, not 24: the counter resets on every power-on, so at a once-daily cycle a
# 24 h backstop expires at the same instant as the scheduled wake it backs up.
# `timing-windows` owns that relationship; this pins that the value reaches
# the board.
assert_eq "26"  "$(reg_dec "$F" 49)" "49 guaranteed wake"
fixture_rm "$F"

# ── The EEPROM-erasure trap ────────────────────────────────────────────────
# initializeRegisters() reads a stored 255 as "never written" and replaces it
# with the compiled default — 0 for register 47. So a 255 here holds until the
# next power loss and then vanishes, on exactly the path the delay exists to
# soften. The value must be 254, and a site asking for 255 must be refused
# rather than quietly given something that erases itself.
describe "default-on delay is never written as 255"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin3s
export WITTYPI_DEFAULT_ON_DELAY=255
run_rpi_unit "$F" wittypi configure
unset WITTYPI_DEFAULT_ON_DELAY
assert_eq "2" "$RUN_RC" "255 is refused"
assert_contains "$RUN_OUT" "never written" "it says why, rather than just failing"
fixture_rm "$F"

# ── Topology is refused, never defaulted ───────────────────────────────────
# The one that protects a battery. A typo silently falling back to "no
# thresholds" would look exactly like a working node until the pack died.
describe "an unrecognised topology is REFUSED, not defaulted"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin_3s
run_rpi_unit "$F" wittypi configure
assert_eq "2" "$RUN_RC" "it exits 2, which the unit does NOT whitelist"
assert_contains "$RUN_OUT" "not a topology" "it names the problem"
if [ -f "$F/regs/17" ]; then
    notok "it wrote nothing at all" \
        "a refused policy must not half-apply — 17 was written before the refusal"
else
    ok "it wrote nothing at all"
fi
fixture_rm "$F"

# ── wp_sanity IS WIRED IN — which is a different claim from "wp_sanity works" ─
# Everything below this file's `sane()` helper calls wp_sanity DIRECTLY, so it
# all passed for weeks while `configure` and `check` invoked it exactly nowhere
# (WITTYPI-SETTINGS.md §7 recorded it as "a check that cannot fire"). A function
# that is tested and never called is indistinguishable, from the test suite's
# side, from one that runs and finds nothing.
#
# So these drive the SUBCOMMANDS and assert the refusal comes out of them. The
# contradiction used is guaranteed-wake 0, because it is reachable purely
# through the environment and needs no fixture surgery.
describe "configure REFUSES a contradictory policy — the wiring, not the function"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_GUARANTEED_WAKE=0
run_rpi_unit "$F" wittypi configure
unset WITTYPI_GUARANTEED_WAKE
assert_eq "2" "$RUN_RC" "configure exits 2 rather than applying it"
assert_contains "$RUN_OUT" "layer 3 is disabled" "the refusal names the contradiction"
if [ -f "$F/regs/17" ]; then
    notok "it wrote nothing at all" "a refused policy must not half-apply"
else
    ok "it wrote nothing at all"
fi
fixture_rm "$F"

describe "check REFUSES the same policy rather than reporting a delta against it"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_GUARANTEED_WAKE=0
run_rpi_unit "$F" wittypi check
unset WITTYPI_GUARANTEED_WAKE
assert_eq "2" "$RUN_RC" "check exits 2"
assert_contains "$RUN_OUT" "layer 3 is disabled" "and says why, rather than listing rows"
fixture_rm "$F"

# ── The temperature pair is POLICY now, both halves ────────────────────────
# If register 44 is owned by nobody — a table that sets 46 and says nothing
# about 44 — lowering the over-temperature point can invert the pair against
# whatever 44 already holds. A repair applied only by hand to one board
# would mean a replacement controller arrives at the factory value and
# reproduces the same inversion.
describe "the below-temperature point is applied, not left to the factory"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "the policy with both temperature rows is coherent"
assert_eq "236" "$(reg_dec "$F" 44)" "register 44 reaches the board as -20C (236)"
assert_eq "70"  "$(reg_dec "$F" 46)" "and 46 is still 70C, the other half of the pair"
fixture_rm "$F"

# ── An UNSET topology is judged against the board, not waved through ───────
# A board with no /data/wittypi.env at all would apply fewer policy rows and
# skip the two voltage cutoffs — behind a warning in the boot journal that's
# easy for nobody to ever read. That's only harmless when the feed happens
# to be USB-C, which is an accident of whatever's on the bench, not a
# property of the design.
#
# The board can say which topology it is actually in (register 7), so the unsafe
# half of "unset" is now a refusal and only the benign half is a warning. These
# two cases are the whole point: one must stop, the other must not.
# ── The site can break the shutdown budget, and only the node can see it ───
# /data/wittypi.env overrides register 21 on any node and is invisible to every
# build-time check. The vendor's own default for it is 7 s, which does not fit
# the mark-good gate plus a measured 6 s shutdown — the rail would be cut with
# /data still mounted.
describe "a site POWER_CUT_DELAY too short for the shutdown is REFUSED"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_POWER_CUT_DELAY=7          # the vendor default
run_rpi_unit "$F" wittypi configure
unset WITTYPI_POWER_CUT_DELAY
assert_eq "2" "$RUN_RC" "configure exits 2 rather than applying it"
assert_contains "$RUN_OUT" "still mounted" "the refusal names what it costs"
if [ -f "$F/regs/17" ]; then
    notok "it wrote nothing at all" "a refused policy must not half-apply"
else
    ok "it wrote nothing at all"
fi
fixture_rm "$F"

describe "and the shipped value is accepted"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "the default budget is coherent"
assert_eq "250" "$(reg_dec "$F" 21)" "register 21 reaches the board as 25.0s"
fixture_rm "$F"

# ── The register that cost an outage, from the end nobody checked ──────────
# 254 was shipped. WittyPi4.ino:253 computes delay(reg * 1000) in a 16-bit int,
# so anything above 32 wraps negative and becomes ~49.7 days as an unsigned
# long: DEFAULT_ON never fires, input power returns, and the node stays dark.
# The vendor's own tool accepts 0-10.
describe "a default-on delay that overflows the firmware's 16-bit delay is REFUSED"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_DEFAULT_ON_DELAY=254        # what shipped, and what broke
run_rpi_unit "$F" wittypi configure
unset WITTYPI_DEFAULT_ON_DELAY
assert_eq "2" "$RUN_RC" "254 is refused"
assert_contains "$RUN_OUT" "49.7 DAYS" "the refusal names what actually happens"
if [ -f "$F/regs/17" ]; then
    notok "it wrote nothing at all" "a refused policy must not half-apply"
else
    ok "it wrote nothing at all"
fi
fixture_rm "$F"

describe "the boundary is 32, and both sides of it are checked"
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_DEFAULT_ON_DELAY=33         # first value that overflows
run_rpi_unit "$F" wittypi configure
assert_eq "2" "$RUN_RC" "33 is refused — 33000 does not fit a signed 16-bit int"
unset WITTYPI_DEFAULT_ON_DELAY
fixture_rm "$F"
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_DEFAULT_ON_DELAY=32         # largest that works
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "32 is accepted — the largest value the firmware can hold"
assert_eq "32" "$(reg_dec "$F" 47)" "and it reaches the board"
unset WITTYPI_DEFAULT_ON_DELAY
fixture_rm "$F"

describe "the shipped default is inside the vendor's own documented range"
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "the default policy applies"
don=$(reg_dec "$F" 47)
if [ "$don" -ge 0 ] && [ "$don" -le 10 ]; then
    ok "default-on delay ${don}s is within the vendor's 0-10"
else
    notok "default-on delay is within the vendor's 0-10" \
          "got ${don}s — wittyPi.sh:380 accepts 0-10 only, and exceeding it is how 254 shipped"
fi
fixture_rm "$F"

describe "unset topology on VIN is REFUSED — those registers are the pack's protection"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
printf '0x01\n' > "$F/regs/7"          # POWER_MODE 1 = running off the DC/DC input
unset WITTYPI_TOPOLOGY
run_rpi_unit "$F" wittypi configure
assert_eq "2" "$RUN_RC" "it exits 2, which the unit does NOT whitelist"
assert_contains "$RUN_OUT" "protects nothing" "it names what the silence would cost"
if [ -f "$F/regs/17" ]; then
    notok "it wrote nothing at all" \
        "a refused policy must not half-apply — 17 was written before the refusal"
else
    ok "it wrote nothing at all"
fi
fixture_rm "$F"

describe "unset topology on USB-C WARNS and proceeds — but still skips 19 and 22"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
printf '0x00\n' > "$F/regs/7"          # POWER_MODE 0 = 5V USB-C, where 19/22 are inert
unset WITTYPI_TOPOLOGY
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "it applies the rows that do not depend on the topology"
assert_contains "$RUN_OUT" "WITTYPI_TOPOLOGY unset" "it still says the config is missing"
assert_eq "1" "$(reg_dec "$F" 17)" "the topology-independent rows still reach the board"
# The discriminating assertion: 19 and 22 must be UNTOUCHED, not written 255.
# "Never written" and "deliberately disabled" are the distinction this whole
# branch exists to preserve.
for r in 19 22; do
    if [ -f "$F/regs/$r" ]; then
        notok "register $r is left alone" "it was written despite no topology being set"
    else
        ok "register $r is left alone"
    fi
done
fixture_rm "$F"

describe "usb5v refuses a voltage threshold rather than writing an inert one"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_LOW_VOLTAGE=3.4
run_rpi_unit "$F" wittypi configure
unset WITTYPI_LOW_VOLTAGE
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" "inert" "it explains that mode 0 ignores the register"
fixture_rm "$F"

describe "each topology writes its own 19/22, and usb5v disables them"
for spec in "usb5v:255:255" "vin2s:66:70" "vin3s:96:102"; do
    topo=${spec%%:*}; rest=${spec#*:}; wlv=${rest%%:*}; wrv=${rest##*:}
    F=$(fixture_new)
    stub_i2c "$F"
    stub_board_rev7 "$F"
    export WITTYPI_TOPOLOGY="$topo"
    run_rpi_unit "$F" wittypi configure
    assert_eq "0" "$RUN_RC" "$topo applies"
    assert_eq "$wlv" "$(reg_dec "$F" 19)" "$topo low voltage = $wlv"
    assert_eq "$wrv" "$(reg_dec "$F" 22)" "$topo recovery = $wrv"
    assert_eq "0" "$(reg_dec "$F" 41)" "$topo never sets IGNORE_POWER_MODE"
    fixture_rm "$F"
done

describe "vin2s says out loud that the DC/DC dropout is unmeasured"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin2s
run_rpi_unit "$F" wittypi configure
assert_contains "$RUN_OUT" "UNMEASURED" "the warning is not silent"
fixture_rm "$F"

# ── Hysteresis, both directions ────────────────────────────────────────────
describe "recovery below cutoff is refused with the exit code the unit surfaces"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin3s
export WITTYPI_RECOVERY_VOLTAGE=9.0
run_rpi_unit "$F" wittypi configure
unset WITTYPI_RECOVERY_VOLTAGE
assert_eq "2" "$RUN_RC" "exit 2, not 1 — SuccessExitStatus=0 1 would have hidden a 1"
assert_contains "$RUN_OUT" "must EXCEED" "it names the inversion"
fixture_rm "$F"

# The counter-intuitive half: on VIN, guaranteed wake is gated on the RECOVERY
# threshold and zeroes its counter when the check fails, so a high recovery
# voltage can starve layer 3 for weeks. Warn, but do not refuse — it is a
# legitimate if unwise choice, unlike an inverted hysteresis which cannot work.
describe "a recovery threshold near float warns about starving guaranteed wake"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin3s
export WITTYPI_RECOVERY_VOLTAGE=12.3
run_rpi_unit "$F" wittypi configure
unset WITTYPI_RECOVERY_VOLTAGE
assert_eq "0" "$RUN_RC" "it still applies — this is a warning, not a refusal"
assert_contains "$RUN_OUT" "starve layer 3" "it explains the consequence"
assert_eq "123" "$(reg_dec "$F" 22)" "the site's value is honoured"
fixture_rm "$F"

# ── check reports the delta and changes nothing ────────────────────────────
describe "check sees an unconfigured board, and configure fixes it"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin3s
run_rpi_unit "$F" wittypi check
assert_eq "2" "$RUN_RC" "a factory board is out of sync"
assert_contains "$RUN_OUT" "OUT OF SYNC" "it says so"
if [ -f "$F/log/i2cset" ]; then
    notok "check wrote nothing" "check must be read-only; it called i2cset"
else
    ok "check wrote nothing"
fi
run_rpi_unit "$F" wittypi configure
run_rpi_unit "$F" wittypi check
assert_eq "0" "$RUN_RC" "in sync after configure"
assert_contains "$RUN_OUT" "in sync" "and says that too"
fixture_rm "$F"

# ── A write that does not take must FAIL, not be printed ───────────────────
# The rtc-write defect, in the register path: i2cset can fail silently, and a
# row that did not take is indistinguishable from one that did until the
# moment it was needed.
describe "a register that will not take fails the apply"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=vin3s
export WP_DROP_REG=45                 # the over-temperature ACTION
run_rpi_unit "$F" wittypi configure
unset WP_DROP_REG
assert_eq "2" "$RUN_RC" "the apply fails"
assert_contains "$RUN_OUT" "reads back" "it reports what the register actually holds"
assert_contains "$RUN_OUT" "NOT applied" "and does not claim the policy is in place"
fixture_rm "$F"

# ── Stale alarm flags ──────────────────────────────────────────────────────
# Both read 1 on a board that has never had an alarm set, which would make the
# first "why did I wake" answer a lie. Cleared only when no schedule exists, so
# that once something is writing alarms this cannot destroy state it does not
# own.
describe "stale alarm flags are cleared, but only when no schedule is set"
F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
printf '0x01\n' > "$F/regs/39"
printf '0x01\n' > "$F/regs/40"
export WITTYPI_TOPOLOGY=vin3s
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$(reg_dec "$F" 39)" "flag 39 cleared on a scheduleless board"
assert_eq "0" "$(reg_dec "$F" 40)" "flag 40 cleared"
fixture_rm "$F"

F=$(fixture_new)
stub_i2c "$F"
stub_board_rev7 "$F"
printf '0x01\n' > "$F/regs/39"
printf '0x30\n' > "$F/regs/29"         # alarm1 hour = 30 BCD: a schedule exists
export WITTYPI_TOPOLOGY=vin3s
run_rpi_unit "$F" wittypi configure
assert_eq "1" "$(reg_dec "$F" 39)" \
    "a live schedule's flags are left alone — this must not reach into state it does not own"
fixture_rm "$F"
unset WITTYPI_TOPOLOGY

# ── 0xFF is also what a FAILED READ looks like ─────────────────────────────
# The second 255 problem, distinct from the EEPROM sentinel. An I2C read that
# NAKs leaves SDA high and reads 0xFF while i2cget still exits 0 — there is no
# error to check.
#
# The failure that matters is not the glitch, it is what believes it:
# bcd2dec(255) = 165, so an unvalidated RTC read yields "month 165" and hands it
# to date -s; and wp_present treating a glitched register 0 as "not fitted"
# makes wittypi-daemon exit 0 and skip the power sequencing for a whole boot.

# i2cget pops one value per call from $F/seq/<reg>, repeating the last once
# exhausted — so a test can script a glitch followed by good reads.
stub_i2c_seq() {
    mkdir -p "$1/seq"
    {
        printf '#!/bin/sh\n'
        printf 'f="%s/seq/$4"\n' "$1"
        printf '[ -f "$f" ] || { echo 0x00; exit 0; }\n'
        printf 'v=$(sed -n 1p "$f")\n'
        printf 'sed -i 1d "$f" 2>/dev/null\n'
        printf '[ -s "$f" ] || printf "%%s\\n" "$v" > "$f"\n'
        printf 'printf "%%s\\n" "$v"\n'
    } > "$1/bin/i2cget"
    chmod +x "$1/bin/i2cget"
}
# $2 is deliberately unquoted: `printf '%s\n'` with several words emits one
# line per word, which is exactly how a read SEQUENCE is expressed here.
# Quoting it would write a single line and every glitch test would silently
# become a single-read test that passes for the wrong reason.
# shellcheck disable=SC2086
seq_set() { printf '%s\n' $2 > "$1/seq/$3"; }
hw_call() { _f=$1; shift; ( PATH="$_f/bin:$PATH" sh -c ". '$LIB'; $*" 2>/dev/null ); }

describe "a configuration register is read until two reads agree"
F=$(fixture_new); stub_i2c_seq "$F"
seq_set "$F" "0x96 0x96" 21
assert_eq "150" "$(hw_call "$F" wp_get_stable 21)" "two agreeing reads return the value"
seq_set "$F" "0xff 0x96 0x96" 21
assert_eq "150" "$(hw_call "$F" wp_get_stable 21)" "a glitched first read is outvoted by a third"
seq_set "$F" "0x01 0x02 0x03" 21
hw_call "$F" wp_get_stable 21 >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc" "three distinct values is refused, not averaged"
fixture_rm "$F"

describe "wp_reg_is_stable_class excludes exactly what wp_get_stable's own header says it must"
# 1/3/5: recomputed by the firmware only when THESE registers are read
# (requestEvent()/getInputVoltage() et al., confirmed against WittyPi4.ino
# directly) — never expected to agree between two reads. 50-71: the proxied
# RTC/temp block, ticks or floats on its own. Everything else, including the
# decimal telemetry halves (2/4/6 — they change only as a side effect of
# reading 1/3/5, never independently) and the new alarm registers (27-36),
# only changes when this design writes it.
F=$(fixture_new)
for wp_r in 1 3 5 50 58 64 71; do
    hw_call "$F" wp_reg_is_stable_class "$wp_r" >/dev/null 2>&1 && rc=0 || rc=1
    assert_eq "1" "$rc" "register $wp_r is excluded (return 1, not stable-class)"
done
for wp_r in 0 2 4 6 21 27 30 36 49; do
    hw_call "$F" wp_reg_is_stable_class "$wp_r" >/dev/null 2>&1 && rc=0 || rc=1
    assert_eq "0" "$rc" "register $wp_r is stable-class (return 0)"
done
fixture_rm "$F"

describe "wp_get_maybe_stable outvotes a glitch on a stable-class register"
F=$(fixture_new); stub_i2c_seq "$F"
seq_set "$F" "0xff 0x96 0x96" 21
assert_eq "150" "$(hw_call "$F" wp_get_maybe_stable 21)" \
    "register 21 (POWER_CUT_DELAY) routes through wp_get_stable and rides out the glitch"
fixture_rm "$F"

describe "wp_get_maybe_stable does NOT hold live telemetry to the same standard"
# If this routed register 1 through wp_get_stable too, two back-to-back
# DIFFERENT readings — which is what a live, recomputed-on-read register is
# SUPPOSED to give — would read as "the bus is not reliable" and refuse. A
# single plain read is correct here; the sequence below would fail the
# stability check if wp_get_maybe_stable's dispatch were wrong.
F=$(fixture_new); stub_i2c_seq "$F"
seq_set "$F" "0x04 0x05 0x06" 1
assert_eq "4" "$(hw_call "$F" wp_get_maybe_stable 1)" \
    "register 1 (VIN integer, live) returns the FIRST read, unaveraged"
fixture_rm "$F"

describe "a glitched register 0 does not read as 'no controller fitted'"
# The expensive direction: wittypi-daemon exits 0 on a missing controller, so
# believing one bad read costs SYS_UP, the GPIO-4 watch and the rail cut for
# that entire boot — and logs it as the normal bench case.
F=$(fixture_new); stub_i2c_seq "$F"
seq_set "$F" "0xff 0x26 0x26" 0
hw_call "$F" wp_present && rc=0 || rc=1
assert_eq "0" "$rc" "one 0xFF glitch does not declare the controller absent"
seq_set "$F" "0x00 0x00" 0
hw_call "$F" wp_present && rc=0 || rc=1
assert_eq "1" "$rc" "a consistently wrong id IS absent"
fixture_rm "$F"

# The six RTC fields as a real clock would hold them: 2026-08-13 22:29:39.
rtc_good() {
    seq_set "$1" "0x39" 58; seq_set "$1" "0x29" 59; seq_set "$1" "0x22" 60
    seq_set "$1" "0x13" 61; seq_set "$1" "0x08" 63; seq_set "$1" "0x26" 64
}

describe "the clock reads correctly when the bus behaves"
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
out=$(hw_call "$F" wp_rtc_read); rc=$?
assert_eq "0" "$rc" "a clean read succeeds"
assert_eq "2026-08-13 22:29:39" "$out" "and reports the time it was given"
fixture_rm "$F"

describe "an out-of-range field is refused rather than decoded"
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0xff" 63                      # month: bcd2dec(255) = 165
out=$(hw_call "$F" wp_rtc_read); rc=$?
assert_eq "1" "$rc" "a 0xFF month fails the read"
assert_eq "" "$out" "and prints no timestamp for date -s to swallow"
fixture_rm "$F"

describe "seconds ADVANCING under the read is fine — only a carry is not"
# This assertion is deliberately looser than requiring seconds to be
# IDENTICAL either side of the five field reads — a stricter rule sounds
# safer but fails in practice: each field is a separate fork+exec of
# i2cget, and on a slow single-core board under boot load six of those can
# easily exceed a second between the first and last. A strict equality rule
# can then never hold at exactly the moment the board needs a clock, and it
# ends up never getting one.
#
# The invariant that matters is that no CARRY into minutes occurred. Seconds
# advancing 39 -> 41 cannot have carried; only a wrap 59 -> 00 can. So an
# advance is accepted and the LATER seconds reported.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
# The sequence must never repeat a value: the stub returns a constant once
# its sequence is exhausted, so a short sequence could let a later attempt
# see s1 == s2 and pass for the wrong reason — appearing to test the
# advancing case while actually re-testing strict equality. Every read here
# advances, so equality can never hold on any attempt.
seq_set "$F" "0x39 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48 0x49 0x50 0x51 0x52 0x53" 58
out=$(hw_call "$F" wp_rtc_read); rc=$?
assert_eq "0" "$rc" "an advancing read succeeds"
assert_eq "2026-08-13 22:29:41" "$out" "and reports the LATER seconds"
fixture_rm "$F"

describe "...but a MINUTE BOUNDARY straddle is still refused"
# The case the bracketing exists for: at 22:29:59 -> 22:30:00 the minutes field
# read before the carry and the seconds after it, so reporting them together
# gives a time a full minute wrong — and at a year boundary, a year.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
# Six attempts, each wrapping 59 -> 00.
seq_set "$F" "0x59 0x00 0x59 0x00 0x59 0x00 0x59 0x00 0x59 0x00 0x59 0x00" 58
out=$(hw_call "$F" wp_rtc_read); rc=$?
assert_eq "1" "$rc" "a wrap under the read is refused"
assert_eq "" "$out" "and nothing is printed for date -s to swallow"
fixture_rm "$F"

# ── wp_rtc_read_confirmed — a second opinion across whole reads ────────────
# These pin what the function DOES catch (a one-off glitch on a single
# field, like the documented register-17 misread) and what it CANNOT (a
# consistently wrong clock, which real hardware has actually shown) — the
# second is a deliberate, documented limit, not an oversight, and this test
# exists so it stays that way rather than silently changing shape.

describe "two consecutive agreeing reads confirm the time"
# rtc_good's registers are each a single repeating value, so every full read
# gives the same answer — the ordinary, no-glitch case.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
out=$(hw_call "$F" wp_rtc_read_confirmed); rc=$?
assert_eq "0" "$rc" "confirmed read succeeds"
assert_eq "2026-08-13 22:29:39" "$out" "and reports the agreed time"
fixture_rm "$F"

describe "a single glitched field is outvoted, not believed"
# Hour reads 10 once (a stand-in for the measured register-17 shape: a glitch
# landing ON a valid value, not an out-of-range one) then settles on the real
# 22. The first full read (10) and second (22) disagree by 12h and are
# rejected; the second and third both read 22 and agree.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x10 0x22" 60
out=$(hw_call "$F" wp_rtc_read_confirmed); rc=$?
assert_eq "0" "$rc" "confirmed read recovers"
assert_eq "2026-08-13 22:29:39" "$out" "and reports the value two reads agreed on, not the glitch"
fixture_rm "$F"

describe "a STABLE wrong clock is confirmed anyway — the known, documented limit"
# The failure this function CANNOT catch, pinned so it stays honest. Hour
# reads 10 on every attempt — not a glitch, a consistently wrong RTC, a
# failure mode real hardware has actually shown. Every read agrees with
# the last, because the RTC itself is wrong, not any one read of it.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x10" 60
out=$(hw_call "$F" wp_rtc_read_confirmed); rc=$?
assert_eq "0" "$rc" "confirmed read succeeds — it has no way to know 10 is wrong"
assert_eq "2026-08-13 10:29:39" "$out" "and reports the stable, wrong hour with full confidence"
fixture_rm "$F"

describe "a clock that never settles is refused, not guessed at"
# Hour alternates 01/13 every attempt, so no two consecutive reads are ever
# within WP_RTC_CONFIRM_SLOP of each other across all 5 default tries.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x01 0x13 0x01 0x13 0x01" 60
out=$(hw_call "$F" wp_rtc_read_confirmed); rc=$?
assert_eq "1" "$rc" "refuses after WP_RTC_CONFIRM_MAX tries"
assert_eq "" "$out" "and prints nothing for a caller to mistake for a value"
fixture_rm "$F"

describe "a flat coin cell (year 00) is propagated as-is, not retried past"
# wp_rtc_read returns 1 WITH output for exactly the lost-power case. Retrying
# it would just confirm 2000-01-01 five times and hide the real signal behind
# this function's own job of filtering noise — see its header.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x00" 64
out=$(hw_call "$F" wp_rtc_read_confirmed); rc=$?
assert_eq "1" "$rc" "a lost-power read still fails"
assert_eq "2000-08-13 22:29:39" "$out" "and the year-00 timestamp is still printed, for the caller to detect"
fixture_rm "$F"

# ── rtc-sync must only ever move the clock FORWARD ─────────────────────────
# This has happened for real: systemd had already recovered a good clock
# from a persisted timesync file, and this command dragged it backwards from
# a stale RTC:
#
#   Aug 14 17:36:42  Starting Set the system clock from the Witty Pi 4 RTC...
#   Mar 13 16:17:37  system clock set from RTC: 2026-03-13 16:17:37
#
# Every timestamp after that was wrong, and on a board whose wake schedule is
# computed from the clock, backwards is the direction that makes an alarm fire
# late or not at all. Both plausible sources hold only times the board has
# actually seen, so the later of the two is the better one.
#
# `date` is stubbed to answer the three forms rtc-sync uses, so the test does
# not depend on today's date. `date -s` writes a marker: its ABSENCE is the
# assertion, since "did not set the clock" is the whole behaviour.
stub_date_now() {
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '  *-s*)  echo SET >> "%s/log/date-set"; exit 0 ;;\n' "$1"
        printf '  *-d*)  echo %s ;;\n' "$2"      # epoch the RTC string maps to
        printf '  *+%%s*) echo %s ;;\n' "$3"     # epoch of "now"
        printf '  *)     echo "stub-now" ;;\n'
        printf 'esac\n'
    } > "$1/bin/date"
    chmod +x "$1/bin/date"
}

describe "rtc-sync REFUSES to move the clock backwards"
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x26" 0                 # firmware id, so wp_require passes
stub_date_now "$F" 1000 2000          # RTC = 1000, now = 2000 -> RTC is older
run_rpi_unit "$F" wittypi rtc-sync
assert_eq "0" "$RUN_RC" "exits 0 — this is a normal state, not a fault"
assert_contains "$RUN_OUT" "NOT later than the current clock" "says why"
assert_contains "$RUN_OUT" "must not move it backwards" "and states the rule"
assert_eq "" "$(cat "$F/log/date-set" 2>/dev/null)" "and the clock was NOT set"
fixture_rm "$F"

describe "...but an RTC AHEAD of the clock still sets it"
# The half that makes the test above mean something: if both directions
# refused, the guard would be indistinguishable from disabling rtc-sync — which
# is the whole mechanism by which this node gets a time before NTP.
F=$(fixture_new); stub_i2c_seq "$F"; rtc_good "$F"
seq_set "$F" "0x26" 0                 # firmware id, so wp_require passes
stub_date_now "$F" 2000 1000          # RTC = 2000, now = 1000 -> RTC is newer
run_rpi_unit "$F" wittypi rtc-sync
assert_eq "0" "$RUN_RC" "exits 0"
assert_contains "$RUN_OUT" "system clock set from RTC" "it sets the clock"
assert_contains "$(cat "$F/log/date-set" 2>/dev/null)" "SET" "and date -s really ran"
fixture_rm "$F"

# ── Cross-register sanity ──────────────────────────────────────────────────
# `check` compares the board against the policy value by value, so every case
# below PASSES it: each register holds exactly what was asked for. The fault is
# in the combination, which is a thing only a rule about pairs can see.
POL() { printf '%s\n' "$@"; }        # each arg is one "reg<TAB>value<TAB>label"
R() { printf '%s\t%s\t%s' "$1" "$2" "${3:-x}"; }
sane() { hw_call "$1" "wp_sanity \"\$(cat '$1/pol')\"" >/dev/null 2>&1; }
pol_write() { F_=$1; shift; POL "$@" > "$F_/pol"; }

describe "a coherent policy passes"
F=$(fixture_new); stub_i2c_seq "$F"
pol_write "$F" "$(R 17 1)" "$(R 49 24)" "$(R 44 236 below-pt)" "$(R 46 70 over-pt)" \
               "$(R 19 255)" "$(R 22 255)" "$(R 47 254)"
sane "$F" && rc=0 || rc=1
assert_eq "0" "$rc" "the shipped shape is accepted"
fixture_rm "$F"

describe "an over-temp point set without its partner is refused"
# 46 written, 44 never mentioned. Both registers individually correct; the
# pair is what would be wrong.
F=$(fixture_new); stub_i2c_seq "$F"
pol_write "$F" "$(R 17 1)" "$(R 49 24)" "$(R 46 70 over-pt)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "half a temperature pair is refused"
fixture_rm "$F"

describe "inverted temperature points are refused"
F=$(fixture_new); stub_i2c_seq "$F"
pol_write "$F" "$(R 44 75 below-pt)" "$(R 46 70 over-pt)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "below 75C against over 70C is refused"
# And the signed comparison must hold: -20 (236) really is below 70.
F2=$(fixture_new); stub_i2c_seq "$F2"
pol_write "$F2" "$(R 44 236 below-pt)" "$(R 46 70 over-pt)"
sane "$F2" && rc=0 || rc=1
assert_eq "0" "$rc" "-20C (stored 236) is accepted as below 70C, not above it"
fixture_rm "$F"; fixture_rm "$F2"

describe "voltage hysteresis cannot be half-armed or backwards"
F=$(fixture_new); stub_i2c_seq "$F"
pol_write "$F" "$(R 19 255)" "$(R 22 102)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "recovery armed while low voltage is disabled is refused"
pol_write "$F" "$(R 19 96)" "$(R 22 90)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "recovery below low voltage is refused"
pol_write "$F" "$(R 19 96)" "$(R 22 102)"
sane "$F" && rc=0 || rc=1
assert_eq "0" "$rc" "and the right way round is accepted"
fixture_rm "$F"

describe "255 is refused everywhere it would erase itself"
F=$(fixture_new); stub_i2c_seq "$F"
for r in 47 26 24 44; do
    pol_write "$F" "$(R $r 255 trap)"
    sane "$F" && rc=0 || rc=1
    assert_eq "1" "$rc" "register $r written 255 is refused"
done
# 19 and 22 are the exception: 255 IS their compiled default, so it survives.
pol_write "$F" "$(R 19 255)" "$(R 22 255)"
sane "$F" && rc=0 || rc=1
assert_eq "0" "$rc" "19 and 22 may hold 255 — it is their own default"
fixture_rm "$F"

describe "the two settings whose absence is silent and expensive"
F=$(fixture_new); stub_i2c_seq "$F"
pol_write "$F" "$(R 17 0)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "default-on 0 is refused — the node would not come back"
pol_write "$F" "$(R 49 0)"
sane "$F" && rc=0 || rc=1
assert_eq "1" "$rc" "guaranteed wake 0 is refused — layer 3 would be gone"
fixture_rm "$F"

# ═══════════════════════════════════════════════════════════════════════════
#  Register NAMES, decoded values, and the help text that lied
# ═══════════════════════════════════════════════════════════════════════════
#
# The drift case below is the point of this section: help text can advertise
# a stale default (e.g. a value that has since been changed after causing a
# real outage) while nothing fails, because nothing compares the help text
# to the code. Both now read one set of WP_FALLBACK_ assignments, and these
# assertions are what keeps that true.

describe "every register this design touches has a name, both ways"
# Parameter expansion rather than `set -- $_pair`: the split would be
# deliberate, but shellcheck cannot know that and a suppression here would
# train the eye to skip SC2086 in a file full of shell quoting.
for _pair in "21 POWER_CUT_DELAY" "47 DEFAULT_ON_DELAY" "49 GUARANTEED_WAKE" \
             "17 DEFAULT_ON" "11 ACTION_REASON" "13 SITE_MARK" "44 BELOW_TEMP_POINT"; do
    _reg=${_pair%% *}; _name=${_pair##* }
    assert_eq "$_name" "$(hw_call "$F" wp_reg_name "$_reg")" "register $_reg is named $_name"
    assert_eq "$_reg" "$(hw_call "$F" wp_reg_num "$_name")"  "the name $_name resolves to $_reg"
done
assert_eq "21" "$(hw_call "$F" wp_reg_num power-cut-delay)" \
    "names are case- and hyphen-insensitive, because nobody remembers which"
assert_eq "21" "$(hw_call "$F" wp_reg_num WP_REG_POWER_CUT_DELAY)" \
    "the lib's own WP_REG_ prefix is tolerated"
assert_eq "47" "$(hw_call "$F" wp_reg_num I2C_CONF_DEFAULT_ON_DELAY)" \
    "so is the firmware's I2C_CONF_ prefix"
assert_eq "21" "$(hw_call "$F" wp_reg_num 21)" "a number is still a number"

describe "a raw byte is decoded into something a human can be wrong about"
assert_eq "20.0 s"  "$(hw_call "$F" wp_reg_decode 21 200)" "200 in register 21 is 20.0 s, not 200"
assert_eq "-20 C"   "$(hw_call "$F" wp_reg_decode 44 236)" "236 is a SIGNED byte: -20 C"
assert_eq "26 hours" "$(hw_call "$F" wp_reg_decode 49 26)" "register 49 without bit 7 is hours"
assert_eq "13 days" "$(hw_call "$F" wp_reg_decode 49 141)" "with bit 7 set it is days"
assert_eq "disabled" "$(hw_call "$F" wp_reg_decode 19 255)" "255 in a threshold means disabled"
assert_contains "$(hw_call "$F" wp_reg_decode 11 3)" "button" "reason 3 is a button click"
assert_contains "$(hw_call "$F" wp_reg_decode 11 12)" "guaranteed" "reason 12 is guaranteed wake"

describe "DEFAULT_ON states BOTH readings, because nothing can tell them apart"
# The site marker was dropped (it did not fit), so no register distinguishes
# stock from site firmware. Stock powers on only for 1; ours powers on for
# everything but 0x5A. Picking one reading would report "this board will
# come back" about a board that will not.
assert_contains "$(hw_call "$F" wp_reg_decode 17 1)"  "both firmwares" \
    "1 is unambiguous — on under either"
assert_contains "$(hw_call "$F" wp_reg_decode 17 90)" "site fw: WAITS" \
    "0x5A is the site sentinel"
assert_contains "$(hw_call "$F" wp_reg_decode 17 0)"  "stock: WAITS" \
    "0 waits on stock and powers on under ours — both stated"
assert_contains "$(hw_call "$F" wp_reg_decode 13 0)"  "identify firmware by flash checksum" \
    "register 13 says how to identify firmware now that the marker is gone"

describe "the help text cannot drift from the defaults it advertises"
for _v in GUARANTEED_WAKE POWER_CUT_DELAY DEFAULT_ON_DELAY OVER_TEMP BELOW_TEMP; do
    _fallback=$(sed -n "s/^WP_FALLBACK_$_v=\(-\{0,1\}[0-9][0-9]*\).*/\1/p" \
                "$RPI_UNITS_DIR/wittypi" | head -n 1)
    assert_eq "1" "$(grep -c "WITTYPI_$_v:-\$WP_FALLBACK_$_v" "$RPI_UNITS_DIR/wittypi")" \
        "the policy reads WITTYPI_$_v from WP_FALLBACK_$_v, not an inline literal"
    if [ -n "$_fallback" ]; then
        ok "WP_FALLBACK_$_v is set ($_fallback)"
    else
        notok "WP_FALLBACK_$_v is set" "no assignment found — the usage text would print an empty default"
    fi
done
# Comment lines are excluded on purpose — grepping the whole file would also
# match a comment that explains a past drift by quoting the old, wrong text
# verbatim. An assertion that can't tell a warning about a bug from the bug
# itself is not one.
assert_eq "0" "$(grep -v '^[[:space:]]*#' "$RPI_UNITS_DIR/wittypi" \
                 | grep -c 'default 254\|default 24 \|default 15 ')" \
    "no hand-typed default survives in the help text itself"

describe "the RTC calibration offset is policy, because a flash erases it"
# Register 37 is a value a firmware flash destroys for good.
# initializeRegisters() does not seed it, so an erased EEPROM leaves it at zero
# rather than at anything sane; and it is a measured property of one crystal, so
# no image default could be right. UUGear's own instructions say to back it up
# and write it back by hand — a hand step on a board that then runs for years.
# The symptom of forgetting is a clock that drifts, which is the one thing this
# board was chosen to prevent.
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
export WITTYPI_TOPOLOGY=usb5v
export WITTYPI_RTC_OFFSET=119
run_rpi_unit "$F" wittypi configure
unset WITTYPI_RTC_OFFSET
assert_eq "119" "$(reg_dec "$F" 37)" "a site RTC offset reaches register 37"

F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
run_rpi_unit "$F" wittypi configure
# Guarded on a register the policy DOES write, so a fixture that silently
# wrote nothing cannot pass this — a broken stub that leaves configure
# writing nothing at all must not let "register 37 is left alone" pass for
# entirely the wrong reason.
if [ ! -f "$F/regs/21" ]; then
    notok "the fixture actually ran configure" "register 21 was never written — the stub is broken, so the next assertion means nothing"
elif [ -f "$F/regs/37" ]; then
    notok "register 37 is left alone when no site value is set" \
        "it wrote $(reg_dec "$F" 37) — an image-wide default would be WRONG on every other board"
else
    ok "register 37 is left alone when no site value is set, but the rest of the policy applied"
fi

F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
export WITTYPI_RTC_OFFSET=300
run_rpi_unit "$F" wittypi configure
unset WITTYPI_RTC_OFFSET WITTYPI_TOPOLOGY
assert_eq "2" "$RUN_RC" "an offset that is not a byte is refused"
assert_contains "$RUN_OUT" "not a byte" "and it says why"

describe "check tells you to restart the UNIT, not to run configure by hand"
# /data/wittypi.env is loaded by systemd's EnvironmentFile=, which an
# interactive shell does not source. So `wittypi configure` typed at a prompt
# applies COMPILED defaults and silently discards every site value.
#
# A `wittypi check` hint that just says "run: wittypi configure" would send
# someone to overwrite a correctly-configured register with a stale compiled
# default, against a board that was never actually out of sync — the hint
# itself would be the bug, not the board.
assert_eq "0" "$(grep -c 'run: wittypi configure' "$RPI_UNITS_DIR/wittypi")" \
    "the bare-command hint is gone"
assert_eq "1" "$(grep -c 'run: systemctl restart wittypi-configure.service' "$RPI_UNITS_DIR/wittypi")" \
    "check points at the unit, which is the only thing that reads the env file"
if grep -q 'NOT bare' "$RPI_UNITS_DIR/wittypi"; then
    ok "and it says explicitly why the bare command is wrong"
else
    notok "it says why the bare command is wrong" \
        "a hint that just changes the command teaches nothing; the next person types the old one"
fi
