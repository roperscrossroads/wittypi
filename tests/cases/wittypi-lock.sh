#!/bin/sh
# The I2C lock actually reaches the units that are supposed to carry it.
#
# WHY A SEPARATE FILE FROM wake-guard.sh
# ---------------------------------------
# wake-guard.sh proves the LOCK MECHANISM works (a contended flock is treated
# as unreadable, nothing is written, it releases cleanly). This file proves
# the mechanism actually reached the shipped units — a text/shape check on the
# unit files themselves, and the cheapest possible defence against a unit being
# edited later without noticing the wrap quietly fell off.
#
# Several assert_contains calls below match LITERAL shell text ($VAR, ${..})
# inside single quotes on purpose — that is the string being searched for in
# the target file, not something meant to expand here. The directive has to
# precede the first command to be file-scoped and carry no trailing prose,
# exactly as wittypi.sh's own stub_i2c_seq notes (SC2016).
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

describe "the three boot/NTP-triggered units wrap their ExecStart in the shared lock"
for pair in \
    "wittypi-configure.service:/usr/bin/wittypi configure" \
    "wittypi-clock.service:/usr/bin/wittypi rtc-sync" \
    "wittypi-rtc-save.service:/usr/bin/wittypi rtc-write"
do
    unit="${pair%%:*}"; cmd="${pair#*:}"
    path="$RPI_SYSTEMD_DIR/$unit"
    assert_file_exists "$path" "$unit ships"
    text=$(cat "$path" 2>/dev/null)
    assert_contains "$text" "ExecStart=/usr/bin/flock -w 10 /run/wittypi.lock $cmd" \
        "$unit's ExecStart is wrapped: flock -w 10 /run/wittypi.lock, then $cmd"
done

describe "the scheduler — the fourth wrapped unit, and the first WRITER among them"
# It lives in wittypi-ops (OPS_UNITS_DIR), not this repo, so it's asserted
# here separately rather than forced into the loop above — and guarded,
# since this repo doesn't carry that package. Same 10s class: boot-time,
# never on the shutdown clock — and the wrap matters MORE here than on the
# readers, because wp_arm_alarm's TERM trap must run while still holding the
# lock or a half-written alarm could race wake-guard's 1s wait.
if have "${RPI_SYSTEMD_DIR:-}/wittypi-schedule.service" "wittypi-schedule.service (wittypi-ops layer)"; then
SCHED_UNIT_TEXT=$(cat "$RPI_SYSTEMD_DIR/wittypi-schedule.service" 2>/dev/null)
assert_contains "$SCHED_UNIT_TEXT" \
    "ExecStart=/usr/bin/flock -w 10 /run/wittypi.lock /usr/libexec/site/wittypi-schedule" \
    "wittypi-schedule.service's ExecStart is wrapped in the shared lock"
fi

describe "every wrapped unit this repo ships uses the SAME lock file — a second lock path would not serialize anything"
# The scheduler unit (wittypi-ops) would need to be part of this same check to
# be a complete cross-package guarantee — see the SKIP above if it's absent.
LOCKS=$(grep -h 'flock -w 10 ' \
    "$RPI_SYSTEMD_DIR/wittypi-configure.service" \
    "$RPI_SYSTEMD_DIR/wittypi-clock.service" \
    "$RPI_SYSTEMD_DIR/wittypi-rtc-save.service" \
    | sed -n 's#.*flock -w 10 \(/run/[^ ]*\) .*#\1#p' | sort -u)
LOCK_COUNT=$(printf '%s\n' "$LOCKS" | grep -c .)
assert_eq "1" "$LOCK_COUNT" "exactly one distinct lock path across this repo's units ($LOCKS)"
assert_eq "/run/wittypi.lock" "$LOCKS" "and it is /run/wittypi.lock — the same default wake-guard falls back to"

describe "wake-guard's own default lock path matches the units' hardcoded one"
# wake-guard reads WAKE_GUARD_LOCK with this as the fallback. If the two
# drifted, a locked unit and wake-guard would each hold a DIFFERENT lock and
# believe they were serialized against each other while not being so at all
# — worse than no lock, because it would look like protection.
if have "${UNITS_DIR:-}/wake-guard" "wake-guard — the integration layer owns it"; then
GUARD_TEXT=$(cat "$UNITS_DIR/wake-guard" 2>/dev/null)
assert_contains "$GUARD_TEXT" 'WP_LOCK="${WAKE_GUARD_LOCK:-/run/wittypi.lock}"' \
    "wake-guard's fallback lock path is /run/wittypi.lock"
fi

describe "the lock is 10s for the boot-time units — generous, since none compete with a shutdown clock"
for unit in wittypi-configure.service wittypi-clock.service wittypi-rtc-save.service; do
    text=$(cat "$RPI_SYSTEMD_DIR/$unit" 2>/dev/null)
    assert_contains "$text" "flock -w 10 " "$unit waits up to 10s for the lock, not indefinitely"
done

describe "wake-guard's own internal lock is short — 1s, not 10s"
# This is the one that must never match the boot-time units' 10s. wake-guard
# runs inside wake-guard.service's TimeoutStopSec=5 (and inline in
# wittypi-daemon's own shutdown sequence) — a 10s wait here could all by
# itself exceed the whole power-cut budget before any actual work starts.
if have "${UNITS_DIR:-}/wake-guard" "wake-guard — the integration layer owns it"; then
assert_contains "$GUARD_TEXT" "flock -w 1 9" \
    "wake-guard waits at most 1s for the lock before treating it as unreadable"
fi
