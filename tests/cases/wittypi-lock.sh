#!/bin/sh
# The I2C lock reaches the shipped units the way the design says: taken by
# the SCRIPT, not by a flock wrapper on ExecStart.
#
# WHY A SEPARATE FILE FROM wittypi-lib-lock.sh
# ---------------------------------------------
# wittypi-lib-lock.sh proves the MECHANISM (wp_lock against a real flock
# holder). This file proves the mechanism reached the shipped units — a
# text/shape check on the unit files and the CLI, the cheapest defence
# against a unit edited later so that a wrapper quietly comes back (a wrapper
# plus an in-script lock waits on itself), or a lock timeout gets listed as a
# success.
#
# Several assert_contains calls match LITERAL shell text ($VAR) inside single
# quotes on purpose (SC2016).
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

unit_body() { grep -v '^[[:space:]]*#' "$RPI_SYSTEMD_DIR/$1"; }

describe "the three boot/NTP-triggered units run the bare tool — it takes the lock itself"
for pair in \
    "wittypi-configure.service:/usr/bin/wittypi configure" \
    "wittypi-clock.service:/usr/bin/wittypi rtc-sync" \
    "wittypi-rtc-save.service:/usr/bin/wittypi rtc-write"
do
    unit="${pair%%:*}"; cmd="${pair#*:}"
    assert_file_exists "$RPI_SYSTEMD_DIR/$unit" "$unit ships"
    body=$(unit_body "$unit")
    assert_contains "$body" "ExecStart=$cmd" "$unit's ExecStart is $cmd, unwrapped"
    assert_not_contains "$body" "flock" "$unit carries no flock (a wrapper plus the in-script lock would wait on itself)"
done

describe "the scheduler still runs under its unit's wrapper — until its script takes the lock itself"
# wittypi-schedule takes no lock in-script yet; its wrapper is what keeps
# wp_arm_alarm's writes serialised. The commit that moves the lock into the
# script removes the wrapper in the same change, and flips this assertion.
if have "${RPI_SYSTEMD_DIR:-}/wittypi-schedule.service" "wittypi-schedule.service"; then
assert_contains "$(unit_body wittypi-schedule.service)" \
    "ExecStart=/usr/bin/flock -w 10 /run/wittypi.lock /usr/libexec/site/wittypi-schedule" \
    "wittypi-schedule.service's ExecStart is still wrapped in the shared lock"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$OPS_UNITS_DIR/wittypi-schedule")" "wp_lock" \
    "and the script takes none of its own (both at once would deadlock)"
fi

describe "a lock timeout (75) is a success status on NO unit; a stand-down (69) only where the tool cannot be conditioned"
for u in "$RPI_SYSTEMD_DIR"/*.service; do
    n=$(basename "$u")
    st=$(grep -v '^[[:space:]]*#' "$u" | sed -n 's/^SuccessExitStatus=//p')
    case " $st " in
        *" 75 "*) notok "$n: 75 is not a success" "SuccessExitStatus=$st" ;;
        *) ok "$n: 75 is not a success (${st:-none listed})" ;;
    esac
done
assert_contains " $(unit_body wittypi-rtc-save.service | sed -n 's/^SuccessExitStatus=//p') " " 69 " \
    "rtc-save lists 69: its .path would re-trigger an ExecCondition in a loop, so the tool stands down itself"
for n in wittypi-clock.service wittypi-configure.service; do
    assert_not_contains " $(unit_body $n | sed -n 's/^SuccessExitStatus=//p') " " 69 " "$n does not list 69"
done

describe "the clock unit: probe before lock, and a start timeout that covers both"
u=$(unit_body wittypi-clock.service)
assert_contains "$u" "Environment=WITTYPI_PROBE_SEC=15" "WITTYPI_PROBE_SEC=15"
assert_contains "$u" "Environment=WITTYPI_LOCK_WAIT=15" "WITTYPI_LOCK_WAIT=15 — the boot-time class"
probe=$(printf '%s\n' "$u" | sed -n 's/^Environment=WITTYPI_PROBE_SEC=//p')
lockw=$(printf '%s\n' "$u" | sed -n 's/^Environment=WITTYPI_LOCK_WAIT=//p')
start=$(printf '%s\n' "$u" | sed -n 's/^TimeoutStartSec=//p')
if [ "${start:-0}" -ge $(( ${probe:-0} + ${lockw:-0} + 10 )) ]; then
    ok "TimeoutStartSec $start >= probe $probe + lock $lockw + 10 for the RTC read"
else
    notok "TimeoutStartSec covers probe + lock + the read" "start=$start probe=$probe lock=$lockw"
fi

describe "configure and the watch load the policy file AFTER the site file, so the floored value wins"
for n in wittypi-configure.service wittypi-watch.service; do
    envs=$(unit_body "$n" | sed -n 's/^EnvironmentFile=//p' | tr '\n' ' ')
    assert_eq "-/data/wittypi.env -/run/wittypi/policy.env " "$envs" "$n: site file, then policy file (both optional)"
done

describe "the CLI locks every bus-touching subcommand in the right mode, and rtc-sync only after its probe"
cli=$(grep -v '^[[:space:]]*#' "$RPI_UNITS_DIR/wittypi")
assert_eq "6" "$(printf '%s\n' "$cli" | grep -c 'wp_cli_lock s 10')" "six shared takers at 10 s: status, rtc, temp, get, regs, check"
assert_contains "$cli" 'wp_cli_lock s 15' "rtc-sync: shared, 15 s"
assert_eq "3" "$(printf '%s\n' "$cli" | grep -c 'wp_cli_lock x 20')" "three exclusive takers, 20 s: set, rtc-write, configure"
assert_eq "3" "$(printf '%s\n' "$cli" | grep -c 'wp_cli_stand_down$')" "and the same three stand down under a halt"
assert_not_contains "$cli" "flock" "the CLI never calls flock directly — the lib's wp_lock is the one lock"
for sub in names halt-status; do
    body=$(printf '%s\n' "$cli" | sed -n "/^$sub)/,/^    ;;/p")
    assert_not_contains "$body" "wp_cli_lock" "$sub takes no lock (no I2C)"
    assert_not_contains "$body" "wp_require" "$sub does not even probe the bus"
done

describe "the lock path the units imply is the lib's default, and wake-guard's"
assert_contains "$(grep -v '^[[:space:]]*#' "$RPI_UNITS_DIR/wittypi-lib.sh")" 'WP_LOCK="${WITTYPI_LOCK:-/run/wittypi.lock}"' \
    "the lib's lock is /run/wittypi.lock"
if have "${UNITS_DIR:-}/wake-guard" "wake-guard — the integration layer owns it"; then
GUARD_TEXT=$(cat "$UNITS_DIR/wake-guard" 2>/dev/null)
assert_contains "$GUARD_TEXT" 'WP_LOCK="${WAKE_GUARD_LOCK:-/run/wittypi.lock}"' \
    "wake-guard's fallback lock path is the same file — a second path would serialise nothing"
assert_contains "$GUARD_TEXT" "flock -w 1 9" \
    "wake-guard waits at most 1s for the lock: it runs inside a 5 s stop timeout on the power-cut clock"
fi

describe "rtc-save orders on the clock unit, not on a target nothing pulls in"
t=$(unit_body wittypi-rtc-save.service)
assert_contains "$t" "After=wittypi-clock.service" "After=wittypi-clock.service"
assert_not_contains "$t" "time-sync.target" "no inert After=time-sync.target"
assert_contains "$t" "ConditionPathExists=/run/systemd/timesync/synchronized" "the sync marker is still the gate"
