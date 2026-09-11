#!/bin/sh
# wittypi-schedule + wp_arm_alarm — the on-node scheduler.
#
# Functional: the SHIPPED script runs against the real wittypi-lib.sh with
# i2cget/i2cset stubbed — reads scripted per-register (the wittypi.sh seq
# technique) on top of a stateful register file that i2cset writes into, so
# read-backs see what was actually written; WP_DROP_REG models a write that
# silently does not take, WP_BLOCK_REG one that hangs mid-sequence. date is
# REAL: the anchor under test is the stubbed RTC, not the host clock.
#
# The SIGTERM case is written from scratch — the wake-guard trap it mirrors
# was proven by hand against a stalling controller and never committed as a
# test. Mechanics: the first write to the HOUR register blocks; the script
# is TERMed (the shell defers the trap while a foreground child runs), then
# the blocked i2cset is killed, which lets the trap fire against a free
# stub. What must remain: day AND seconds zeroed, alarm2 never touched.
#
# Every refusal case asserts the same two things: the named reason, and an
# EMPTY i2cset log — a scheduler that refuses after writing something has
# already failed at its one job.
#
# The stubs are GENERATED shell; single quotes are the point (SC2016).
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

SCHED="$OPS_UNITS_DIR/wittypi-schedule"
SCHED_UNIT="$RPI_SYSTEMD_DIR/wittypi-schedule.service"
SCHED_PATH="$RPI_SYSTEMD_DIR/wittypi-schedule.path"
RESCHED_UNIT="$RPI_SYSTEMD_DIR/wittypi-reschedule.service"
WATCH="$OPS_UNITS_DIR/wittypi-watch"
AUDIT="$OPS_UNITS_DIR/wittypi-audit"
LIB="$RPI_UNITS_DIR/wittypi-lib.sh"
# The Yocto recipe that packages these scripts lives in the meta-wittypi
# layer repo, not this one — there is no path inside this tree to guess at.
# WITTYPI_YOCTO_OPS_RECIPE lets an integration build point these cases at it;
# absent that they SKIP by name. Same convention as WITTYPI_YOCTO_RECIPE in
# wittypi-board-env.sh.
OPS_BB="${WITTYPI_YOCTO_OPS_RECIPE:-}"
TIMING_WINDOWS="$RPI_DIR/timing-windows"

# i2cget serves a scripted per-register sequence when one exists, else the
# register file i2cset maintains, else 0x00 — so read-backs see real writes
# while glitch tests still script exact read patterns.
stub_sched_i2c() {
    mkdir -p "$1/regs" "$1/seq"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/i2cset"\n' "$1"
        printf 'if [ "$4" = "${WP_BLOCK_REG:-none}" ] && [ ! -f "%s/blocked" ]; then\n' "$1"
        printf '    : > "%s/blocked"\n' "$1"
        printf '    sleep 30\n'
        printf 'fi\n'
        printf '[ "$4" = "${WP_DROP_REG:-none}" ] && exit 0\n'
        printf 'printf "%%s\\n" "$5" > "%s/regs/$4"\n' "$1"
    } > "$1/bin/i2cset"
    {
        printf '#!/bin/sh\n'
        printf 'f="%s/seq/$4"\n' "$1"
        printf 'if [ -f "$f" ]; then\n'
        printf '    v=$(sed -n 1p "$f")\n'
        printf '    sed -i 1d "$f" 2>/dev/null\n'
        printf '    [ -s "$f" ] || printf "%%s\\n" "$v" > "$f"\n'
        printf '    printf "%%s\\n" "$v"\n'
        printf '    exit 0\n'
        printf 'fi\n'
        printf 'if [ -f "%s/regs/$4" ]; then cat "%s/regs/$4"; else echo 0x00; fi\n' "$1" "$1"
    } > "$1/bin/i2cget"
    chmod +x "$1/bin/i2cset" "$1/bin/i2cget"
}
# shellcheck disable=SC2086
seq_set() { printf '%s\n' $2 > "$1/seq/$3"; }

# Controller present (reg 0), guaranteed wake 26 h (reg 49 = 0x1a), a
# readable RTC at 2026-08-13 22:29:39, a terms file with the measured
# T_MARKGOOD, and a valid schedule: ON 420 / OFF 1800 (floor is 312+60=372;
# cycle 2220 fits 26 h with an hour to spare).
sched_fixture() {
    _sf=$(fixture_new)
    stub_sched_i2c "$_sf"
    stub "$_sf" notify 'exit 0'
    printf '0x26\n' > "$_sf/regs/0"
    printf '0x1a\n' > "$_sf/regs/49"
    printf '0x39\n' > "$_sf/regs/58"
    printf '0x29\n' > "$_sf/regs/59"
    printf '0x22\n' > "$_sf/regs/60"
    printf '0x13\n' > "$_sf/regs/61"
    printf '0x08\n' > "$_sf/regs/63"
    printf '0x26\n' > "$_sf/regs/64"
    printf 'T_MARKGOOD=312\n' > "$_sf/terms"
    printf 'WITTYPI_SCHEDULE_ON_SEC=420\nWITTYPI_SCHEDULE_OFF_SEC=1800\n' \
        > "$_sf/data/wittypi-schedule.env"
    printf '%s' "$_sf"
}

run_sched() {
    _f="$1"; shift
    RUN_OUT=$(
        PATH="$_f/bin:$PATH" \
        WITTYPI_SCHEDULE_LIB="$LIB" \
        WITTYPI_SCHEDULE_ENV="$_f/data/wittypi-schedule.env" \
        WITTYPI_SCHEDULE_TERMS="$_f/terms" \
        WITTYPI_SITE_ENV="$_f/data/wittypi.env" \
        WITTYPI_SCHEDULE_NOTIFY="$_f/bin/notify" \
        PROC_UPTIME="$_f/proc/uptime" \
        sh "$SCHED" "$@" 2>&1
    )
    RUN_RC=$?
    return 0
}

# The register sequence i2cset saw, space-joined — order is most of what
# this file exists to pin.
set_seq() { cut -d' ' -f4 "$1/log/i2cset" 2>/dev/null | tr '\n' ' '; }

# ── the clean run: both alarms, the order, the values ──────────────────────

describe "a clean run arms wake-then-shutdown, day last in each, flags cleared after"
# The expected instants are phase-anchored, not "RTC + ON_SEC". The
# fixture's RTC (22:29:39) sits at phase 1959 of the 2220s cycle — past this
# window's 420s ON, i.e. the node is awake during what the schedule calls
# sleep, which is exactly what an off-phase boot looks like (a plug-in, the
# button, guaranteed wake). So this window's stop is already spent and the
# scheduler advances one whole cycle: stop 22:41:00, wake 22:41:00 + OFF.
F=$(sched_fixture)
run_sched "$F"
assert_eq "0" "$RUN_RC" "exits 0"
assert_eq "27 28 29 30 39 32 33 34 35 40 " "$(set_seq "$F")" \
    "alarm1 sec,min,hour,DAY then its flag; only then alarm2 the same way — nothing else, nothing reordered"
assert_contains "$RUN_OUT" 'armed register-27 alarm for day 13 at 23:11:00 UTC' "the wake: the stop plus OFF"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 13 at 22:41:00 UTC' "the shutdown: the next cycle boundary plus ON"
assert_contains "$RUN_OUT" 'skipping 1 cycle(s)' "and it says why it advanced"
assert_contains "$RUN_OUT" 'cycle ON 420s / OFF 1800s' "and the summary names the cycle"
assert_eq "0x13" "$(cat "$F/regs/30" 2>/dev/null)" "alarm1 day landed as BCD"
assert_eq "0x41" "$(cat "$F/regs/33" 2>/dev/null)" "alarm2 minute landed as BCD"
assert_eq "0" "$(cat "$F/regs/39" 2>/dev/null)" "alarm1's stale triggered-flag cleared"
assert_eq "0" "$(cat "$F/regs/40" 2>/dev/null)" "alarm2's too"
assert_eq "" "$(stub_log "$F" notify)" "nothing to page on success"
fixture_rm "$F"

describe "the appointments are ABSOLUTE PHASE, so the sleep is always exactly OFF"
# The property the whole repair path rests on. Both instants are multiples
# of the cycle offset by ON/0 — never offsets from the moment of the run.
F=$(sched_fixture)
run_sched "$F"
_stop=$(date -u -d '2026-08-13 22:41:00' +%s)
_wake=$(date -u -d '2026-08-13 23:11:00' +%s)
assert_eq "420"  "$(( _stop % 2220 ))" "the stop sits ON_SEC into a cycle boundary"
assert_eq "0"    "$(( _wake % 2220 ))" "the wake IS a cycle boundary"
assert_eq "1800" "$(( _wake - _stop ))" "and the sleep is exactly OFF_SEC — what keeps bound 2's guaranteed-wake margin true"
fixture_rm "$F"

describe "IDEMPOTENT: running it again mid-window computes the SAME pair"
# The property that makes repair safe. wittypi-watch re-runs this unit to heal
# a stale alarm2; under a `now + ON_SEC` anchor every such run would push the
# shutdown further out, so a repair would silently redefine the duty cycle.
# Here a second run 90s later must land on exactly the same two instants.
F=$(sched_fixture)
run_sched "$F"
_first=$(printf '%s' "$RUN_OUT" | grep -o 'shutdown [0-9-]* [0-9:]*')
# Advance the stubbed RTC 90s (22:29:39 -> 22:31:09) and run again.
printf '0x09\n' > "$F/regs/58"; printf '0x31\n' > "$F/regs/59"
run_sched "$F"
_second=$(printf '%s' "$RUN_OUT" | grep -o 'shutdown [0-9-]* [0-9:]*')
assert_eq "$_first" "$_second" "same shutdown instant 90s later — a re-run is a no-op, not a new schedule"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 13 at 22:41:00 UTC' "and it is still the phase-anchored value"
fixture_rm "$F"

describe "in-window boot: the CURRENT window's stop is used, no cycle skipped"
# The ordinary scheduled case — alarm1 fired at a cycle boundary, so the
# node wakes at phase ~0 and the stop it wants is this window's own.
F=$(sched_fixture)
# 21:57:00 is a cycle boundary; the ON window runs to 22:04:00. An RTC of
# 21:58:00 is 60s into it, which is where alarm1 leaves a node.
printf '0x00\n' > "$F/regs/58"; printf '0x58\n' > "$F/regs/59"
printf '0x21\n' > "$F/regs/60"; printf '0x13\n' > "$F/regs/61"
run_sched "$F"
assert_eq "0" "$RUN_RC" "exits 0"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 13 at 22:04:00 UTC' "this window's stop — boundary + ON"
assert_contains "$RUN_OUT" 'armed register-27 alarm for day 13 at 22:34:00 UTC' "and the next boundary as the wake"
assert_not_contains "$RUN_OUT" 'skipping' "nothing was skipped"
fixture_rm "$F"

describe "a cycle that divides the hour lands the window on WALL-CLOCK boundaries"
# The values below are fixture inputs, not any particular deployment's
# cadence — the cadence in force is site config this repo cannot see, and
# WITTYPI.md "The window, and where to put it" covers choosing one. What is
# under test is a PROPERTY of the phase anchor that holds for any cycle
# dividing 3600.
#
# Boundaries are multiples of CYCLE since the epoch, and the epoch begins at
# 00:00:00 UTC, so a cycle that divides an hour puts every wake on the hour and
# every stop at a fixed offset into it — regardless of when the run happened.
# That is what makes an awake window predictable from the far end of a
# duty-cycled backhaul instead of something you watch for. Under a
# `now + ON_SEC` anchor these instants would move on every single boot.
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=3300\nWITTYPI_SCHEDULE_OFF_SEC=300\n' \
    > "$F/data/wittypi-schedule.env"
printf '0x31\n' > "$F/regs/58"; printf '0x21\n' > "$F/regs/59"
printf '0x03\n' > "$F/regs/60"; printf '0x25\n' > "$F/regs/61"
run_sched "$F"
assert_eq "0" "$RUN_RC" "exits 0"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 25 at 03:55:00 UTC' "the stop is HH:55:00, not RTC+ON"
assert_contains "$RUN_OUT" 'armed register-27 alarm for day 25 at 04:00:00 UTC' "and the wake is exactly on the hour"
fixture_rm "$F"

describe "...and an arbitrary run time within that cycle lands on the SAME boundaries"
# The idempotence property again, this time across two runs 34 minutes apart
# rather than 90 seconds — a re-run is a no-op no matter WHEN in the window it
# happens, which is what lets the supervisor call it at any tick.
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=3300\nWITTYPI_SCHEDULE_OFF_SEC=300\n' \
    > "$F/data/wittypi-schedule.env"
printf '0x00\n' > "$F/regs/58"; printf '0x05\n' > "$F/regs/59"
printf '0x03\n' > "$F/regs/60"; printf '0x25\n' > "$F/regs/61"
run_sched "$F"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 25 at 03:55:00 UTC' "03:05 run -> same stop"
printf '0x00\n' > "$F/regs/58"; printf '0x39\n' > "$F/regs/59"
run_sched "$F"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 25 at 03:55:00 UTC' "03:39 run -> same stop"
assert_contains "$RUN_OUT" 'armed register-27 alarm for day 25 at 04:00:00 UTC' "and the same wake"
fixture_rm "$F"

describe "the root cause: a config written while the node is UP does nothing until re-run"
# The scheduler reads /data/wittypi-schedule.env exactly once, at boot. If the
# file does not exist then, it exits 0 down the documented hand-scheduled path
# having written nothing — and nothing re-reads it for the rest of that
# uptime. Create the schedule a minute later and the node looks configured to
# every tool that examines it (the watch checks the same file) while its alarm
# block still holds whatever it held before.
#
# That is a node that believes it has a duty cycle and has not armed one, and
# the only thing that would have fixed it was a reboot.
F=$(sched_fixture)
rm -f "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "0" "$RUN_RC" "no config at boot is a clean no-op, not a failure"
assert_contains "$RUN_OUT" 'hand-scheduled mode' "and it says which mode it took"
assert_eq "" "$(set_seq "$F")" "NOTHING was armed — the alarm block still holds whatever it held"

# The config appears mid-uptime. Nothing re-reads it on its own...
printf 'WITTYPI_SCHEDULE_ON_SEC=3300\nWITTYPI_SCHEDULE_OFF_SEC=300\n' \
    > "$F/data/wittypi-schedule.env"
assert_eq "" "$(set_seq "$F")" "still nothing armed just because the file now exists"

# ...but a re-run is all it takes, which is precisely what the supervisor's
# repair path does within one tick instead of one reboot.
run_sched "$F"
assert_eq "0" "$RUN_RC" "the re-run succeeds"
assert_contains "$RUN_OUT" 'armed register-32 alarm' "and NOW the shutdown is armed"
assert_contains "$RUN_OUT" 'armed register-27 alarm' "and the wake"
fixture_rm "$F"

describe "the mark-good floor: a stop this boot could not survive is pushed a cycle"
# The failure this prevents is self-inflicted slot condemnation. Bound 1
# proves a WHOLE window clears T_MARKGOOD (312s); it cannot prove the
# REMAINDER of one does. Same in-window RTC as above — stop 360s out — but
# with the node only 10s into its boot, so mark-good does not land until
# 302s from now and the +60 margin puts the floor 362s out. Six seconds too
# late for this window, so the scheduler takes the next one rather than arm
# a shutdown that lands before boot-slot-health can mark the slot good.
F=$(sched_fixture)
printf '0x00\n' > "$F/regs/58"; printf '0x58\n' > "$F/regs/59"
printf '0x21\n' > "$F/regs/60"; printf '0x13\n' > "$F/regs/61"
set_uptime "$F" 10
run_sched "$F"
assert_eq "0" "$RUN_RC" "exits 0"
assert_contains "$RUN_OUT" 'skipping 1 cycle(s)' "it advanced rather than condemn a healthy slot"
assert_contains "$RUN_OUT" 'mark-good floor' "and named the reason"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 13 at 22:41:00 UTC' "the NEXT window's stop"
fixture_rm "$F"

describe "absent config is the supported hand-scheduled mode: clean no-op"
F=$(sched_fixture)
rm "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "0" "$RUN_RC" "exits 0 — this is not a failure"
assert_contains "$RUN_OUT" 'hand-scheduled mode' "and says which mode the node is in"
assert_eq "" "$(set_seq "$F")" "no register is touched"
fixture_rm "$F"

describe "no controller AND no schedule: exit 0 quietly — the bench norm"
# Unchanged, and it must stay unchanged: a Pi with no HAT and no duty cycle
# is a supported configuration, and a bench node that fails a unit on every
# boot is how you train people to ignore the failures that matter.
F=$(sched_fixture)
rm -f "$F/data/wittypi-schedule.env"
printf '0x00\n' > "$F/regs/0"
run_sched "$F"
assert_eq "0" "$RUN_RC" "still a clean no-op"
assert_contains "$RUN_OUT" 'hand-scheduled mode' "and it is the CONFIG that decides, so that is the reason given"
assert_eq "" "$(set_seq "$F")" "no writes"
assert_eq "" "$(stub_log "$F" notify)" "and nobody is paged for a bench Pi"
fixture_rm "$F"

describe "OPTED IN with no controller: a HAZARD, not a no-op"
# Gate ordering is the whole point here. Running controller-first means an
# unanswering probe exits 0 — "no controller on the bus" — before anything
# looks at whether this node is opted in. systemd records success, nothing
# pages, and the single explanatory line is info-level into a volatile
# journal, so it does not survive the reboot.
#
# With a schedule configured the same silence means NOTHING WILL ARM AND
# NOTHING WILL SHUT THIS NODE DOWN — the one failure direction this design has
# no exit from.
F=$(sched_fixture)
printf '0x00\n' > "$F/regs/0"                       # controller answers nothing
export WITTYPI_SCHEDULE_PROBE_TRIES=2               # keep the test fast
run_sched "$F"
assert_eq "2" "$RUN_RC" "exits NON-ZERO — systemd must show this failed"
assert_contains "$RUN_OUT" 'OPTED IN' "and names the distinction that makes it a fault"
assert_contains "$RUN_OUT" 'NOTHING IS ARMED' "with the consequence"
assert_contains "$RUN_OUT" 'Not a bench no-op' "and rules out the benign reading explicitly"
assert_contains "$(stub_log "$F" notify)" 'will not stop itself' "paged while the network is still up"
assert_eq "" "$(set_seq "$F")" "and it still wrote nothing"
unset WITTYPI_SCHEDULE_PROBE_TRIES
fixture_rm "$F"

describe "the probe is RETRIED — a cold controller is not an absent one"
# The failure mode here is a race, not a dead board: after a long unpowered
# period the scheduler can probe ~15s into boot and get nothing, while a read
# of the same controller minutes later succeeds. The stub answers 0x00 twice
# and then correctly, which must succeed.
F=$(sched_fixture)
mkdir -p "$F/seq"
printf '0x00\n0x00\n0x26\n' > "$F/seq/0"
export WITTYPI_SCHEDULE_PROBE_TRIES=10
run_sched "$F"
assert_eq "0" "$RUN_RC" "it waited for the device to exist, and then scheduled"
assert_contains "$RUN_OUT" 'answered on probe' "and says the controller was not ready at start"
assert_contains "$RUN_OUT" 'armed register-32 alarm' "the shutdown really was armed"
assert_eq "" "$(stub_log "$F" notify)" "a slow controller is not worth paging about"
unset WITTYPI_SCHEDULE_PROBE_TRIES
fixture_rm "$F"

# ── refusals: loud, named, exit 2, and above all WRITE NOTHING ─────────────

describe "a missing ON_SEC is refused"
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_OFF_SEC=1800\n' > "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'REFUSING' "loudly"
assert_contains "$RUN_OUT" 'ON_SEC' "naming the variable"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "a non-integer OFF_SEC is refused"
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=420\nWITTYPI_SCHEDULE_OFF_SEC=30m\n' > "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'not a plain integer' "with the reason"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "an ON window under the mark-good floor is refused — it would condemn healthy slots"
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=300\nWITTYPI_SCHEDULE_OFF_SEC=1800\n' > "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'mark-good floor 372s' "the floor is T_MARKGOOD 312 + 60, derived not hardcoded"
assert_contains "$RUN_OUT" 'condemn' "and the consequence is named"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "an unreadable terms file is refused — a measured term is never defaulted"
F=$(sched_fixture)
rm "$F/terms"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'T_MARKGOOD' "naming the missing term"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "a cycle that does not fit an hour inside guaranteed wake is refused"
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=420\nWITTYPI_SCHEDULE_OFF_SEC=93000\n' > "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused (93420 > 26h - 1h = 90000)"
assert_contains "$RUN_OUT" 'guaranteed wake' "against the live backstop"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "register 49's day unit (bit 7) is decoded, not assumed"
F=$(sched_fixture)
printf '0x81\n' > "$F/regs/49"
run_sched "$F"
assert_eq "0" "$RUN_RC" "1 DAY of guaranteed wake fits the 2220s cycle fine"
printf '0x81\n' > "$F/regs/49"
printf 'WITTYPI_SCHEDULE_ON_SEC=420\nWITTYPI_SCHEDULE_OFF_SEC=85000\n' > "$F/data/wittypi-schedule.env"
: > "$F/log/i2cset"
run_sched "$F"
assert_eq "2" "$RUN_RC" "but 85420s does not fit 86400-3600"
assert_eq "" "$(set_seq "$F")" "and the refusal wrote nothing"
fixture_rm "$F"

describe "guaranteed wake DISABLED is refused — no scheduler without the layer-3 backstop"
F=$(sched_fixture)
printf '0x00\n' > "$F/regs/49"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'DISABLED' "by name"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "an unreadable guaranteed-wake register is refused"
F=$(sched_fixture)
seq_set "$F" "0x01 0x02 0x03 0x04 0x05 0x06" 49
run_sched "$F"
assert_eq "2" "$RUN_RC" "no two agreeing reads means no schedule"
assert_contains "$RUN_OUT" 'unreadable' "and says so"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "a flat RTC (year 00) is refused — appointments from an epoch clock are armed misses"
F=$(sched_fixture)
printf '0x00\n' > "$F/regs/64"
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'lost power' "naming the coin cell, not a vague read error"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

describe "an RTC that never settles is refused"
F=$(sched_fixture)
seq_set "$F" "0x01 0x13 0x01 0x13 0x01" 60
run_sched "$F"
assert_eq "2" "$RUN_RC" "refused"
assert_contains "$RUN_OUT" 'could not be read consistently' "distinct from the year-00 verdict"
assert_eq "" "$(set_seq "$F")" "nothing written"
fixture_rm "$F"

# ── partial failures: the direction of every fallback is the safe one ──────

describe "alarm1 read-back failure backs out day-first and NEVER touches alarm2"
F=$(sched_fixture)
export WP_DROP_REG=30
run_sched "$F"
unset WP_DROP_REG
assert_eq "1" "$RUN_RC" "an arming failure is exit 1, not a refusal"
assert_eq "27 28 29 30 30 29 28 27 " "$(set_seq "$F")" \
    "the four writes, then the back-out day-first — and register 32 never appears"
assert_contains "$RUN_OUT" 'read-back did NOT match' "wp_arm_alarm says why"
assert_contains "$RUN_OUT" 'alarm2 deliberately untouched' "and the script names the direction: a node that stays up beats one that sleeps with no wake"
assert_contains "$(stub_log "$F" notify)" 'could not arm the wake' "and it pages while the network is still up"
fixture_rm "$F"

describe "alarm2 failure after alarm1 landed leaves the wake armed"
F=$(sched_fixture)
export WP_DROP_REG=35
run_sched "$F"
unset WP_DROP_REG
assert_eq "1" "$RUN_RC" "exit 1"
assert_eq "0x13" "$(cat "$F/regs/30" 2>/dev/null)" "alarm1's day survives — the node WILL wake"
assert_eq "27 28 29 30 39 32 33 34 35 35 34 33 32 " "$(set_seq "$F")" \
    "alarm1 fully armed + flag, then alarm2's attempt and its day-first back-out"
assert_contains "$RUN_OUT" 'not self-stop' "the benign direction is stated"
assert_contains "$(stub_log "$F" notify)" 'not the shutdown' "and paged"
fixture_rm "$F"

describe "SIGTERM mid-write: the trap clears day AND seconds, and alarm2 is never reached"
F=$(sched_fixture)
export WP_BLOCK_REG=29
PATH="$F/bin:$PATH" \
    WITTYPI_SCHEDULE_LIB="$LIB" \
    WITTYPI_SCHEDULE_ENV="$F/data/wittypi-schedule.env" \
    WITTYPI_SCHEDULE_TERMS="$F/terms" \
    WITTYPI_SCHEDULE_NOTIFY="$F/bin/notify" \
    sh "$SCHED" >"$F/out" 2>&1 &
sched_pid=$!
i=0
while [ ! -f "$F/blocked" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
# TERM the script first (the shell defers the trap while its foreground
# child runs), then kill the blocked i2cset so the trap can fire.
kill -TERM "$sched_pid" 2>/dev/null
pkill -TERM -f "$F/bin/i2cset" 2>/dev/null || true
wait "$sched_pid" 2>/dev/null
unset WP_BLOCK_REG
assert_file_exists "$F/blocked" "the sequence really was interrupted mid-write (hour register in flight)"
assert_contains "$(cat "$F/out" 2>/dev/null)" 'interrupted mid-write' "the trap says what it did"
assert_eq "0" "$(cat "$F/regs/30" 2>/dev/null)" "day zeroed — nothing can match"
assert_eq "0" "$(cat "$F/regs/27" 2>/dev/null)" "seconds zeroed too — the midnight-combination brace"
assert_not_contains "$(set_seq "$F")" "32" "alarm2 was never reached"
fixture_rm "$F"

# ── shape: the invariants a refactor must not lose ─────────────────────────

describe "the scheduler anchors on the RTC, never the Linux clock"
sched_body=$(grep -v '^\s*#' "$SCHED")
assert_contains "$sched_body" 'wp_rtc_read_confirmed' "the anchor is the controller's own clock"
assert_not_contains "$sched_body" 'date -u +%s' "never a bare Linux now"
assert_not_contains "$sched_body" 'i2cset' "registers only through the lib"
assert_not_contains "$sched_body" 'flock' "the lock is the unit's job, so the trap runs under it"
assert_contains "$sched_body" 'wp_arm_alarm "$WP_REG_ALARM1_SEC"' "arms through the shared function, alarm1 by name"

describe "the scheduler's defaults are the production paths"
sched_default() { sed -n "s/^$1=\"\${[A-Z_]*:-\([^}]*\)}\"\$/\1/p" "$SCHED" | head -1; }
assert_eq "/usr/libexec/site/wittypi-lib.sh" "$(sched_default WP_SCHED_LIB)"   "WP_SCHED_LIB"
assert_eq "/data/wittypi-schedule.env"       "$(sched_default WP_SCHED_ENV)"   "WP_SCHED_ENV"
assert_eq "/usr/lib/site/timing-terms"       "$(sched_default WP_SCHED_TERMS)" "WP_SCHED_TERMS"
assert_eq "/usr/bin/notify"                  "$(sched_default WP_SCHED_NOTIFY)" "WP_SCHED_NOTIFY"

describe "the three tools agree on the one config path"
watch_sched_default=$(sed -n 's/^WP_WATCH_SCHEDULE="\${[A-Z_]*:-\([^}]*\)}"$/\1/p' "$WATCH" | head -1)
audit_sched_default=$(sed -n 's/^WP_AUDIT_SCHEDULE="\${[A-Z_]*:-\([^}]*\)}"$/\1/p' "$AUDIT" | head -1)
assert_eq "/data/wittypi-schedule.env" "$watch_sched_default" "the watch reads the same file"
assert_eq "/data/wittypi-schedule.env" "$audit_sched_default" "the audit too"

describe "the mark-good margin cannot drift from timing-windows' check 7"
sched_margin=$(sed -n 's/.*wp_sched_mg + \([0-9][0-9]*\) )).*/\1/p' "$SCHED" | head -1)
tw_margin=$(sed -n 's/.*T_MARKGOOD + \([0-9][0-9]*\).*/\1/p' "$TIMING_WINDOWS" | head -1)
assert_eq "$tw_margin" "$sched_margin" "one margin, two enforcers (currently $tw_margin)"

describe "the unit's ordering — the serialized boot chain, and stop-inversion for wake-guard"
unit_text=$(grep -v '^#' "$SCHED_UNIT")
assert_contains "$unit_text" 'After=wittypi-clock.service wittypi-configure.service' "clock then configure precede the schedule"
assert_contains "$unit_text" 'After=wake-guard.service' "stopped BEFORE wake-guard's arming ExecStop at shutdown"
assert_not_contains "$unit_text" 'Before=wake-guard' "Before= would run ensure against the scheduler's held lock"
assert_not_contains "$unit_text" 'Before=wittypi.service' "and SYS_UP is not delayed behind the schedule"
assert_contains "$unit_text" 'Conflicts=shutdown.target' "stopped early in the transition"
assert_contains "$unit_text" 'RequiresMountsFor=/data' "the config's mount is a requirement"

describe "the unit's mechanics"
assert_contains "$unit_text" 'Type=oneshot' "a boot oneshot"
assert_contains "$unit_text" 'RemainAfterExit=yes' "the verdict stays visible in systemctl status"
assert_contains "$unit_text" 'TimeoutStartSec=60' "the run is bounded — 60s since the probe retry can add 10s on a cold controller"
assert_contains "$unit_text" 'TimeoutStopSec=5' "and the trap-only stop too"
assert_contains "$unit_text" 'ExecStart=/usr/bin/flock -w 10 /run/wittypi.lock /usr/libexec/site/wittypi-schedule' "lock-wrapped like every boot-time writer"
assert_not_contains "$unit_text" 'EnvironmentFile' "the script sources its own config — a typed run must behave identically"
assert_contains "$unit_text" 'WantedBy=multi-user.target' "enabled"

describe "the recipe ships and enables it"
if have "$OPS_BB" "wittypi-ops_1.0.bb (meta-wittypi layer)"; then
bb=$(cat "$OPS_BB")
# ── ASSERT THE DESTINATION, NOT THE FETCH OR THE SOURCE LAYOUT ────────────
# These used to require `file://wittypi-schedule.service` in SRC_URI and a
# source path of ${S}/wittypi-schedule.service. Both were facts about the layer
# this repo was extracted FROM, and neither is satisfiable by a layer that
# consumes this repo: how the source is fetched is the integrator's choice, and
# this repo keeps its units in systemd/ rather than flat at the root.
#
# Matching "<name> ${D}" catches the tail of the source path and the start of
# the destination, so it holds for ${S}/systemd/x.service, ${S}/x.service or
# anything else, while still failing if the unit is never installed. That is
# the pattern the .path assertions below already used.
assert_contains "$bb" 'install -m 0755 ${S}/wittypi-schedule ${D}${libexecdir}/site/wittypi-schedule' "script installed executable"
assert_contains "$bb" 'wittypi-schedule.service ${D}${systemd_system_unitdir}' "unit installed to the systemd unit dir"
assert_contains "$bb" 'wittypi-watch.timer wittypi-schedule.service' "and ENABLED in SYSTEMD_SERVICE — the units-agree guard sees both directions"
fi

# ── ERR-PRIORITY VERDICTS: the lines that must outlive the reboot ──────────

describe "a refusal is logged at ERR, so journal-persist keeps it on /data"
# The failure this closes. Where journald is Storage=volatile and a
# journal-persist step copies only priority `err` onto /data, a wp_log that
# writes plain stderr is filed by systemd at `info` — so every refusal this
# tooling prints is erased by the next power cycle, and the only recoverable
# evidence of a failing boot is systemd's own "Failed to start", which IS err.
#
# systemd parses a leading `<N>` on a service's stderr as the syslog priority
# and strips it before storing. 3 is LOG_ERR. INVOCATION_ID is what systemd
# sets for a service invocation, so it is the exact test for "will anything
# parse this prefix".
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=10\nWITTYPI_SCHEDULE_OFF_SEC=1800\n' \
    > "$F/data/wittypi-schedule.env"                      # under the mark-good floor
export INVOCATION_ID=deadbeefdeadbeefdeadbeefdeadbeef
run_sched "$F"
assert_eq "2" "$RUN_RC" "still a refusal"
assert_contains "$RUN_OUT" '<3>wittypi: schedule REFUSING' "tagged <3> = LOG_ERR, which is what survives the power cut"
assert_contains "$RUN_OUT" 'mark-good floor' "and still says why"
unset INVOCATION_ID
fixture_rm "$F"

describe "...but NOT when a human runs it — nothing else strips the prefix"
# These tools are built so a typed run and a unit run behave identically. Only
# systemd's stream parser removes the marker, so at a serial console it would
# be literal noise in front of the one line that matters.
F=$(sched_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=10\nWITTYPI_SCHEDULE_OFF_SEC=1800\n' \
    > "$F/data/wittypi-schedule.env"
run_sched "$F"
assert_eq "2" "$RUN_RC" "same refusal"
assert_not_contains "$RUN_OUT" '<3>' "no marker outside systemd"
assert_contains "$RUN_OUT" 'schedule REFUSING' "and the message is unchanged"
fixture_rm "$F"

describe "the OPTED-IN-with-no-controller hazard is ERR too — it must survive"
F=$(sched_fixture)
printf '0x00\n' > "$F/regs/0"
export WITTYPI_SCHEDULE_PROBE_TRIES=2 INVOCATION_ID=deadbeefdeadbeefdeadbeefdeadbeef
run_sched "$F"
assert_contains "$RUN_OUT" '<3>wittypi: schedule: OPTED IN' "the root-cause state is durable now, not just loud"
unset WITTYPI_SCHEDULE_PROBE_TRIES INVOCATION_ID
fixture_rm "$F"

describe "routine success is NOT promoted — a healthy node writes ZERO bytes to /data"
# journal-persist's whole premise. Promoting ordinary verdicts to err would put
# a write on irreplaceable flash on every single boot, which on a duty-cycled
# node is ~12 a day, for information nobody needs after the fact.
F=$(sched_fixture)
export INVOCATION_ID=deadbeefdeadbeefdeadbeefdeadbeef
run_sched "$F"
assert_eq "0" "$RUN_RC" "a clean run"
assert_not_contains "$RUN_OUT" '<3>' "nothing on the success path is err"
unset INVOCATION_ID
fixture_rm "$F"

# ── the .path that closes "a config written while the node is UP does nothing"

describe "a .path watches the schedule config, so writing it no longer needs a reboot"
path_text=$(cat "$SCHED_PATH")
assert_contains "$path_text" 'PathChanged=/data/wittypi-schedule.env' \
    "watches the config — PathChanged catches BOTH the file appearing and being edited"
assert_not_contains "$path_text" 'PathExists=' \
    "not PathExists: it must re-fire on an edit, not latch on existence"
assert_contains "$path_text" 'RequiresMountsFor=/data' "the config's mount is a requirement"
assert_contains "$path_text" 'WantedBy=multi-user.target' "enabled at boot so it is watching from the start"

describe "the .path must not point at the scheduler directly — the RemainAfterExit trap"
# systemd does not re-trigger a path unit whose target service is still
# active, and wittypi-schedule.service is RemainAfterExit=yes — active from its
# boot run onwards. Aimed straight at it this would fire ONCE and then never
# again, silently. That is the same shape as a timer unit that ticks once per
# boot instead of on its cadence. A negative assertion, so a well-meaning
# "simplification" back to the obvious version fails the suite.
#
# The assertions are line-anchored, not substring. Both unit files explain
# this rule in prose, so a substring test matches the warning that documents
# the trap rather than the directive that avoids it. Assert on the DIRECTIVE —
# the same reason a test for 'DNS=' would match an unrelated 'UseDNS=' line.
assert_eq "1" "$(grep -cE '^Unit=wittypi-reschedule\.service$' "$SCHED_PATH")" "it triggers the wrapper"
assert_eq "0" "$(grep -cE '^Unit=wittypi-schedule\.service$' "$SCHED_PATH")" \
    "NEVER the scheduler itself — RemainAfterExit=yes would make this fire once, forever"

describe "the wrapper exists only to lack RemainAfterExit"
resched_text=$(cat "$RESCHED_UNIT")
assert_contains "$resched_text" 'Type=oneshot' "a oneshot"
assert_eq "0" "$(grep -cE '^RemainAfterExit' "$RESCHED_UNIT")" \
    "ABSENT as a DIRECTIVE, and that is the whole reason this unit exists — it must return to inactive so the .path can trigger again"
assert_contains "$resched_text" 'ExecStart=/usr/bin/systemctl restart wittypi-schedule.service' \
    "restart, not start — start on a RemainAfterExit=yes unit is a silent no-op"
assert_eq "0" "$(grep -cE '^\[Install\]$' "$RESCHED_UNIT")" \
    "triggered, not enabled: enabling it would re-run the scheduler at every boot for nothing"
assert_contains "$resched_text" 'Conflicts=shutdown.target' "stopped early in a shutdown transition"
assert_contains "$resched_text" 'After=wake-guard.service' \
    "and stop-ordered so it can never race the arming ExecStop that matters"

describe "the wrapper's timeout covers the scheduler it waits on"
_st=$(sed -n 's/^TimeoutStartSec=\([0-9][0-9]*\)$/\1/p' "$SCHED_UNIT" | head -n1)
_rt=$(sed -n 's/^TimeoutStartSec=\([0-9][0-9]*\)$/\1/p' "$RESCHED_UNIT" | head -n1)
if [ -n "$_st" ] && [ -n "$_rt" ] && [ "$_rt" -gt "$_st" ]; then
    ok "wrapper ${_rt}s exceeds the scheduler's ${_st}s — it blocks, so it must outlast what it waits for"
else
    notok "wrapper timeout exceeds the scheduler's" "wrapper=$_rt scheduler=$_st"
fi

describe "the recipe ships and enables the .path, and accounts for the wrapper"
if have "$OPS_BB" "wittypi-ops_1.0.bb (meta-wittypi layer)"; then
ops_bb=$(cat "$OPS_BB")
# SRC_URI spelling dropped for the reason given above; the two destination
# assertions below are the ones that mean anything to a consumer.
assert_contains "$ops_bb" "wittypi-schedule.path ${D}" "path installed"
assert_contains "$ops_bb" "wittypi-reschedule.service ${D}" "wrapper installed"
assert_contains "$ops_bb" 'wittypi-watch.timer wittypi-schedule.service wittypi-schedule.path' \
    "the .path is ENABLED; the wrapper is accounted for by its Unit=, exactly as the units-agree guard resolves it"
fi

describe "every unit do_install writes is also in FILES"
# A unit that do_install writes but FILES does not list fails do_package with
# a QA error:
#
#   ERROR: QA Issue: wittypi-ops: Files/directories were installed but not
#   shipped in any package: /usr/lib/systemd/system/wittypi-reschedule.service
#
# A do_check_units_enabled guard does not catch it — that cross-checks
# SYSTEMD_SERVICE against the installed units, and resolves the .path's Unit=
# correctly. What it does not check is FILES. systemd.bbclass auto-adds
# SYSTEMD_SERVICE entries to FILES, so an ENABLED unit is covered for free and
# a deliberately-unlisted one is not — which is exactly the shape of the units
# this repo keeps adding (wittypi-watch.service, wittypi-rtc-save.service, and
# the reschedule wrapper).
#
# Catching it here costs a second. Catching it at do_package costs a full
# parse, a kernel compile and five thousand tasks.
# Read line-by-line rather than word-splitting a substitution (SC2013). The
# whole loop is wrapped in one command substitution so the subshell's output
# reaches the variable — a plain `while read` in a pipeline cannot assign
# outward in POSIX sh.
if have "$OPS_BB" "wittypi-ops_1.0.bb (meta-wittypi layer)"; then
_bb_text=$(cat "$OPS_BB")
_missing=$(sed -n 's|.*\${D}\${systemd_system_unitdir}/\([A-Za-z0-9._-]*\).*|\1|p' "$OPS_BB" \
    | sort -u \
    | while IFS= read -r _u; do
        [ -n "$_u" ] || continue
        case "$_bb_text" in
            *"\${systemd_system_unitdir}/$_u "*|*"\${systemd_system_unitdir}/$_u\\"*) ;;
            *) printf ' %s' "$_u" ;;
        esac
      done)
if [ -z "$_missing" ]; then
    ok "every installed unit appears in FILES"
else
    notok "every installed unit appears in FILES" \
        "installed but not shipped:$_missing — do_package will fail with a QA error"
fi
fi

# ── the UTC display note ──────────────────────────────────────────────────
# Cosmetic, but it rides on every timestamp the fleet reads at 3am, so the
# two states that matter are pinned: absent by default (a shared driver must
# not carry one deployment's timezone), and appended verbatim when a site
# states one. The note is a CONSTANT STRING — there is no conversion here to
# test, which is exactly why this is three assertions and not a date suite.

describe "no site note: timestamps render bare UTC, byte-for-byte as before"
F=$(sched_fixture)
run_sched "$F"
assert_contains "$RUN_OUT" 'day 13 at 23:11:00 UTC' "the wake renders"
# NOT a bare 'UTC (' — the cycle summary legitimately renders "UTC (in 1881s)".
# The negative has to name the instant it is guarding.
assert_not_contains "$RUN_OUT" '23:11:00 UTC (' "and carries no annotation nobody configured"
fixture_rm "$F"

describe "WITTYPI_TZ_NOTE in the site env is appended to every rendered instant"
F=$(sched_fixture)
printf 'WITTYPI_TZ_NOTE=ET:-4/-5\n' > "$F/data/wittypi.env"
run_sched "$F"
assert_contains "$RUN_OUT" 'armed register-27 alarm for day 13 at 23:11:00 UTC (ET:-4/-5)' \
    "the wake carries it"
assert_contains "$RUN_OUT" 'armed register-32 alarm for day 13 at 22:41:00 UTC (ET:-4/-5)' \
    "so does the shutdown"
assert_contains "$RUN_OUT" 'wake 2026-08-13 23:11:00 UTC (ET:-4/-5)' \
    "and the cycle summary carries it too"
fixture_rm "$F"

describe "a quoted value is accepted and the quotes stripped, not printed"
# EnvironmentFile= strips quotes before a unit ever sees them, so a line
# copied out of a systemd-fed config arrives here quoted. Printing
# ("ET:-4/-5") would look like a bug in the tool rather than in the config.
F=$(sched_fixture)
printf 'WITTYPI_TZ_NOTE="ET:-4/-5"\n' > "$F/data/wittypi.env"
run_sched "$F"
assert_contains "$RUN_OUT" 'UTC (ET:-4/-5)' "rendered unquoted"
assert_not_contains "$RUN_OUT" '("ET' "the quotes did not survive into the output"
fixture_rm "$F"
