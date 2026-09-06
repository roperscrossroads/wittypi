#!/bin/sh
# wittypi-watch — the periodic read-only supervisor.
#
# Functional: the real script runs against the real wittypi-lib.sh with
# i2cget stubbed (the same sequence-stub technique wittypi.sh proves
# wp_get_stable with), wake-guard and notify stubbed as executables, and
# `date -u +%s` intercepted so "now" is a controlled input. Each check must
# trigger log+notify+record on its hazard INDEPENDENTLY and stay silent when
# clean; the NTP gate must skip rather than false-positive; lock contention
# (wake-guard state 2) must be skipped, not paged and not retried.
#
# Shape: the unit's ordering DIRECTION is pinned with a negative assertion —
# After=wake-guard.service, never Before= — because systemd inverts ordering
# at stop, so a Before= would run wake-guard's arming ExecStop while a tick
# could still be holding the I2C lock it needs. See the unit's header for the
# full derivation.
#
# The stubs below are GENERATED shell: their $*/${VAR:-} must survive to the
# stub rather than expand at build time — the single quotes are the point.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

WATCH="$OPS_UNITS_DIR/wittypi-watch"
WATCH_UNIT="$RPI_SYSTEMD_DIR/wittypi-watch.service"
WATCH_TIMER="$RPI_SYSTEMD_DIR/wittypi-watch.timer"
LIB="$RPI_UNITS_DIR/wittypi-lib.sh"

# ── the same sequence stub wittypi.sh uses for wp_get_stable ───────────────
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
# shellcheck disable=SC2086
seq_set() { printf '%s\n' $2 > "$1/seq/$3"; }

# `date -u +%s` answers with STUB_NOW; every other invocation (parsing with
# -d, rendering the record timestamp) is the real date. Note "%Y-%m-%d"
# contains the substring "-d", which is why that branch must come first.
stub_date() {
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '    *-d*) exec /bin/date "$@" ;;\n'
        printf '    *+%%s*) echo "${STUB_NOW:-0}" ;;\n'
        printf '    *) exec /bin/date "$@" ;;\n'
        printf 'esac\n'
    } > "$1/bin/date"
    chmod +x "$1/bin/date"
}

# A fixture where every check passes: controller present (reg 0 = 0x26),
# guaranteed wake 26 (0x1a), a readable RTC, and "now" 5s from what it reads.
RTC_TIME='2026-08-13 22:29:39'
RTC_EPOCH=$(date -u -d "$RTC_TIME" +%s)

# The reference instant for the field-data regression case below, hoisted to a
# constant for the same reason RTC_EPOCH is: computed once, at top level, so
# the cases below assign STUB_NOW by arithmetic rather than by command
# substitution inside an export (SC2155/SC2046).
INCIDENT_TIME='2026-08-25 01:53:51'
INCIDENT_EPOCH=$(date -u -d "$INCIDENT_TIME" +%s)

watch_fixture() {
    _wf=$(fixture_new)
    stub_i2c_seq "$_wf"; stub_date "$_wf"
    seq_set "$_wf" "0x26" 0
    seq_set "$_wf" "0x1a" 49
    seq_set "$_wf" "0x39" 58; seq_set "$_wf" "0x29" 59; seq_set "$_wf" "0x22" 60
    seq_set "$_wf" "0x13" 61; seq_set "$_wf" "0x08" 63; seq_set "$_wf" "0x26" 64
    {
        printf '#!/bin/sh\n'
        printf 'exit "${STUB_WG_STATE:-1}"\n'
    } > "$_wf/bin/wake-guard"
    chmod +x "$_wf/bin/wake-guard"
    stub "$_wf" notify 'exit 0'
    # The repair seam is always stubbed. Its production default is
    # /usr/bin/systemctl — an absolute path, so a case that forgets to point
    # it at a fixture does not get a PATH miss, it gets the build host's
    # systemctl and a suite that tries to restart units on the developer's
    # workstation. Stubbing it here, in the shared fixture, means no case can
    # forget; STUB_SYSTEMCTL_RC drives the failure paths.
    stub "$_wf" systemctl 'exit "${STUB_SYSTEMCTL_RC:-0}"'
    touch "$_wf/synced"
    printf '%s' "$_wf"
}

# Tunables that are not paths (STUB_NOW, STUB_WG_STATE,
# WITTYPI_GUARANTEED_WAKE) are EXPORTED by each case — see tests/lib.sh's
# note on why prefix assignments built by expansion cannot work.
run_watch() {
    RUN_OUT=$(
        PATH="$1/bin:$PATH" \
        WITTYPI_WATCH_LIB="$LIB" \
        WITTYPI_WATCH_WAKE_GUARD="$1/bin/wake-guard" \
        WITTYPI_WATCH_NOTIFY="${STUB_NOTIFY_PATH:-$1/bin/notify}" \
        WITTYPI_WATCH_RECORD="$1/data/watch-hazards" \
        WITTYPI_WATCH_SYNCED="$1/synced" \
        WITTYPI_WATCH_SCHEDULE="$1/sched.env" \
        WITTYPI_WATCH_SYSTEMCTL="$1/bin/systemctl" \
        WITTYPI_WATCH_REPAIR_STATE="$1/repairs" \
        WITTYPI_WATCH_REARM_MARK="$1/rearm" \
        PROC_UPTIME="$1/proc/uptime" \
        sh "$WATCH" 2>&1
    )
    RUN_RC=$?
    return 0
}

describe "a clean tick: three checks, no hazard, exit 0"
F=$(watch_fixture)
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "exits 0 when everything holds"
assert_contains "$RUN_OUT" 'guaranteed wake ok (register 49 = 26)' "reports the backstop it read"
assert_contains "$RUN_OUT" 'RTC agrees' "reports the clock comparison"
assert_eq "" "$(stub_log "$F" notify)" "notify is never called on a clean tick"
assert_file_absent "$F/data/watch-hazards" "and no hazard record is created"
unset STUB_NOW
fixture_rm "$F"

describe "guaranteed wake drifted from the site policy"
F=$(watch_fixture)
seq_set "$F" "0x14" 49                                  # 20, but the site says 26
export STUB_NOW=$(( RTC_EPOCH + 5 )) WITTYPI_GUARANTEED_WAKE=26
run_watch "$F"
assert_eq "1" "$RUN_RC" "a hazard exits 1 so the unit shows failed"
assert_contains "$RUN_OUT" 'drifted: register 49 reads 20' "names the drift and both values"
assert_contains "$(stub_log "$F" notify)" '-p high' "notify fires at high priority"
assert_contains "$(cat "$F/data/watch-hazards" 2>/dev/null)" 'drifted' "the durable record carries it"
unset STUB_NOW WITTYPI_GUARANTEED_WAKE
fixture_rm "$F"

describe "guaranteed wake DISABLED is a hazard with no site policy needed"
F=$(watch_fixture)
seq_set "$F" "0x00" 49
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "register 49 = 0 is a hazard"
assert_contains "$RUN_OUT" 'DISABLED' "and says the backstop is off"
unset STUB_NOW
fixture_rm "$F"

describe "no site policy: a nonzero register is accepted as-is"
F=$(watch_fixture)
seq_set "$F" "0x14" 49                                  # 20, and nothing says otherwise
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "readable-and-enabled is the whole check without an expectation"
assert_contains "$RUN_OUT" 'guaranteed wake ok (register 49 = 20)' "still reports what it read"
assert_not_contains "$RUN_OUT" 'drifted' "and invents no drift against a value nobody stated"
unset STUB_NOW
fixture_rm "$F"

describe "an unreadable guaranteed-wake register is a hazard — the unlocked read IS the death detector"
F=$(watch_fixture)
seq_set "$F" "0x01 0x02 0x03 0x04 0x05 0x06" 49         # never two agreeing reads
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "an unstable register is a hazard, not a shrug"
assert_contains "$RUN_OUT" 'unreadable' "and says so"
unset STUB_NOW
fixture_rm "$F"

describe "wake-guard state 2 is SKIPPED — contention must not page"
# wake-guard folds "controller dead" and "another accessor holds the lock"
# into one exit code, deliberately. Paging on it would cry wolf on every
# coincidence with rtc-save; a genuinely dead controller still pages through
# the check above, whose read takes no lock.
F=$(watch_fixture)
export STUB_NOW=$(( RTC_EPOCH + 5 )) STUB_WG_STATE=2
run_watch "$F"
assert_eq "0" "$RUN_RC" "a skipped check is not a hazard"
assert_contains "$RUN_OUT" 'skipped' "the skip is logged, not silent"
assert_eq "" "$(stub_log "$F" notify)" "and nothing is paged"
unset STUB_NOW STUB_WG_STATE
fixture_rm "$F"

describe "the observed fault: an RTC stable, wrong, and twelve hours out"
F=$(watch_fixture)
export STUB_NOW=$(( RTC_EPOCH + 43200 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "a 12h disagreement against a synced clock is a hazard"
assert_contains "$RUN_OUT" 'RTC implausible' "named as implausible"
assert_contains "$RUN_OUT" '43200s' "with the measured delta"
assert_contains "$(cat "$F/data/watch-hazards" 2>/dev/null)" 'implausible' "and recorded durably"
assert_contains "$(stub_log "$F" systemctl)" 'restart --no-block wittypi-rtc-save.service' \
    "and the RTC is corrected from the synced clock, not merely reported"
unset STUB_NOW
fixture_rm "$F"

describe "correcting the RTC defers a re-arm rather than racing one"
# The clock-stepping hazard. Alarms armed against the old RTC are wrong by
# exactly the correction, and the match window is two seconds wide —
# a missed alarm does not fire late, it does not fire at all. So the schedule
# must be recomputed AFTER the RTC write.
#
# Both requests are --no-block and systemd orders neither against the other,
# so asking for both in one tick is a race whose loser arms from the clock
# being corrected. A marker defers the re-arm to a later tick instead. It
# also reaches the case a same-tick chain cannot: an RTC running AHEAD leaves
# alarm2 in the FUTURE, which check 4 reads as healthy and never repairs.
F=$(watch_fixture)
touch "$F/sched.env"
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x23" 34; seq_set "$F" "0x13" 35      # a perfectly healthy future alarm2
export STUB_NOW=$(( RTC_EPOCH + 43200 ))
run_watch "$F"
assert_not_contains "$(stub_log "$F" systemctl)" 'wittypi-schedule.service' \
    "the scheduler is NOT asked in the same tick — that would race the RTC write"
assert_file_exists "$F/rearm" "a marker is left for a later tick instead"

# The next tick: the RTC now agrees, and the deferred re-arm is consumed.
# The stub log accumulates across runs, so it is truncated first — otherwise
# the assertion below would pass on the PREVIOUS tick's entry and prove
# nothing.
: > "$F/log/systemctl"
seq_set "$F" "0x1a" 49
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_contains "$(stub_log "$F" systemctl)" 'wittypi-schedule.service' \
    "now the alarms are recomputed against the corrected clock"
assert_contains "$RUN_OUT" 'a clock that has since been corrected' "and it says why"
assert_file_absent "$F/rearm" "the marker is consumed, so it cannot ask forever"
unset STUB_NOW
fixture_rm "$F"

describe "a clock we do not trust is never used to arm anything"
# The gate that keeps repair from making things worse: if the RTC is
# implausible AND could not be corrected, the scheduler must not be asked to
# re-arm from it. A stale register a human can still read beats a confidently
# wrong appointment.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 9000
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35      # past-dated: would normally repair
export STUB_NOW=$(( RTC_EPOCH + 43200 )) STUB_SYSTEMCTL_RC=1
run_watch "$F"
assert_contains "$RUN_OUT" 'RTC is under suspicion this tick' "the re-arm is refused"
assert_contains "$RUN_OUT" 'armed miss' "and names what it is avoiding"
unset STUB_NOW STUB_SYSTEMCTL_RC
fixture_rm "$F"

describe "the same skew with NO NTP sync is SKIPPED — a floored clock is not an RTC fault"
F=$(watch_fixture)
rm -f "$F/synced"
export STUB_NOW=$(( RTC_EPOCH + 43200 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "no verdict without a trustworthy reference"
assert_contains "$RUN_OUT" 'skipping RTC plausibility' "and the skip says why"
unset STUB_NOW
fixture_rm "$F"

describe "an RTC that never settles is a hazard"
F=$(watch_fixture)
seq_set "$F" "0x01 0x13 0x01 0x13 0x01" 60              # hour alternates forever
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "no two agreeing reads is a hazard"
assert_contains "$RUN_OUT" 'could not be read consistently' "distinct from a skew verdict"
unset STUB_NOW
fixture_rm "$F"

describe "no controller AND no schedule: exit 0, quietly — the bench norm, not a fault"
F=$(fixture_new)
stub_i2c_seq "$F"; stub_date "$F"                       # register 0 reads 0x00
stub "$F" notify 'exit 0'
stub "$F" systemctl 'exit 0'
{ printf '#!/bin/sh\nexit 1\n'; } > "$F/bin/wake-guard"; chmod +x "$F/bin/wake-guard"
run_watch "$F"
assert_eq "0" "$RUN_RC" "nothing to supervise exits 0"
assert_contains "$RUN_OUT" 'no controller' "and says why once"
assert_eq "" "$(stub_log "$F" notify)" "without paging anyone"
fixture_rm "$F"

describe "OPTED IN with no controller: the supervisor says so instead of going quiet"
# The other half of the silent-failure mode. A scheduler that exits 0 quietly
# leaves a node with a configured duty cycle and nothing armed — and this gate,
# being unconditional, would then exit 0 too. Nothing anywhere reports it, and
# check 1 (the controller-death detector) sits BELOW this gate, so it never runs.
#
# The bench case above is untouched; what changed is that a readable schedule
# file makes the same silence mean something.
F=$(fixture_new)
stub_i2c_seq "$F"; stub_date "$F"                       # register 0 reads 0x00
stub "$F" notify 'exit 0'
stub "$F" systemctl 'exit 0'
{ printf '#!/bin/sh\nexit 1\n'; } > "$F/bin/wake-guard"; chmod +x "$F/bin/wake-guard"
touch "$F/sched.env"
run_watch "$F"
assert_eq "1" "$RUN_RC" "a hazard, so the unit shows failed"
assert_contains "$RUN_OUT" 'controller does not answer' "named"
assert_contains "$RUN_OUT" 'every check below is blind' "and says the supervisor itself is compromised"
assert_contains "$(stub_log "$F" notify)" '-p high' "paged"
assert_contains "$(cat "$F/data/watch-hazards" 2>/dev/null)" 'does not answer' "and recorded durably on /data, which survives the reboot"
fixture_rm "$F"

describe "notify missing: the durable record survives — /data is the record, ntfy the courtesy copy"
F=$(watch_fixture)
seq_set "$F" "0x00" 49
export STUB_NOW=$(( RTC_EPOCH + 5 )) STUB_NOTIFY_PATH="$F/bin/no-such-notify"
run_watch "$F"
assert_eq "1" "$RUN_RC" "the hazard verdict does not depend on notify"
assert_contains "$(cat "$F/data/watch-hazards" 2>/dev/null)" 'DISABLED' "the record is written regardless"
unset STUB_NOW STUB_NOTIFY_PATH
fixture_rm "$F"

# ── check 4: the schedule's shutdown appointment ───────────────────────────

describe "no schedule config: check 4 never runs — hand-scheduled nodes cannot page from it"
F=$(watch_fixture)
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "clean"
assert_not_contains "$RUN_OUT" 'alarm2' "not even a log line about alarm2"
unset STUB_NOW
fixture_rm "$F"

describe "a schedule with NO armed alarm2 that CANNOT be repaired is a hazard"
# Still the same condition — the node will not stop itself — but the page is
# now what is left after the repair could not be requested, not the whole
# response to it. STUB_SYSTEMCTL_RC=1 is what makes this the unrepairable
# variant; the repairable one is asserted below.
F=$(watch_fixture)
touch "$F/sched.env"
export STUB_NOW=$(( RTC_EPOCH + 5 )) STUB_SYSTEMCTL_RC=1
run_watch "$F"
assert_eq "1" "$RUN_RC" "hazard exits 1"
assert_contains "$RUN_OUT" 'NO shutdown appointment' "named"
assert_contains "$RUN_OUT" 'could not be re-run' "and that the repair was attempted first"
assert_contains "$(stub_log "$F" notify)" '-p high' "and paged"
assert_contains "$(cat "$F/data/watch-hazards" 2>/dev/null)" 'appointment' "and recorded durably"
unset STUB_NOW STUB_SYSTEMCTL_RC
fixture_rm "$F"

describe "a future alarm2 under a schedule is clean"
F=$(watch_fixture)
touch "$F/sched.env"
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x23" 34; seq_set "$F" "0x13" 35
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "no hazard"
assert_contains "$RUN_OUT" 'alarm2 armed for day 13 at 23:00:00 UTC' "reported in the clear"
unset STUB_NOW
fixture_rm "$F"

describe "the missed shutdown: AWAKE through a past-dated alarm2 — page AND repair"
# The expensive case. The RTC reads 22:29:39, alarm2 still says 21:00:00,
# and this node has been up 9000s — longer than the ~5379s the appointment
# is overdue, so it WAS awake when the moment passed and the scheduled
# shutdown did not happen. Every layer in this design pushes the node up and
# none pushes it down, so there is no automatic exit from here: page.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 9000
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "a hazard"
assert_contains "$RUN_OUT" 'in the PAST' "named as past, with the delta"
assert_contains "$RUN_OUT" 'was AWAKE through it' "and that the node was up for it — the severity-deciding fact"
assert_contains "$RUN_OUT" 'nothing in this design stops a node that stays up' "with the consequence"
assert_contains "$(stub_log "$F" notify)" 'PAST' "paged"
assert_contains "$(stub_log "$F" systemctl)" 'restart --no-block wittypi-schedule.service' \
    "and the scheduler was asked to re-arm — detect AND fix"
unset STUB_NOW
fixture_rm "$F"

describe "the stale leftover: OFF through a past-dated alarm2 — repair, do NOT page"
# The false-alarm class, pinned. Identical registers to the case above; the
# only difference is that this node has been up 60s and the appointment is
# ~5379s overdue, so it cannot have been awake when the moment passed. That is
# a bench unplug (the controller loses power, the coin-cell RTC does not) or
# any cold gap — a stale register, not a missed shutdown, and nothing is being
# drained. Paging here fires at priority 4 saying "the node will not stop
# itself" about a node that had just been switched on.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 60
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "NOT a hazard — the boot scheduler owns this state"
assert_contains "$RUN_OUT" 'it was OFF when that moment passed' "named as a leftover, not a miss"
assert_contains "$RUN_OUT" 'stale leftover' "in those words"
assert_eq "" "$(stub_log "$F" notify)" "and nobody was paged"
assert_contains "$(stub_log "$F" systemctl)" 'restart --no-block wittypi-schedule.service' \
    "but it was still repaired — quiet is not the same as ignored"
unset STUB_NOW
fixture_rm "$F"

describe "regression against observed field data — the pseudo-timestamp path, end to end"
# Every number here comes from an observed controller state rather than from
# invention. The controller held alarm2 = day 19 21:00:23 UTC while its RTC
# read day 25 01:53:51 UTC, and wittypi-watch reported the gap as 449608s.
# That figure exercises the whole month-less pseudo-timestamp path — BCD
# decode, day*86400 folding, and the subtraction — checked end to end against
# an observation rather than against itself:
#
#     sn_ts    = 25*86400 + 1*3600 + 53*60 + 51 = 2166831
#     sched_ts = 19*86400 + 21*3600 +  0*60 + 23 = 1717223
#     overdue  =                                    449608   <- the alert
#
# It also pins the CLASSIFICATION. The node had been powered off for five
# days, so it cannot have been awake when that appointment passed, and the
# correct response is a quiet repair — not a priority-4 page, repeated once
# per tick interval, saying "the node will not stop itself" about a node that
# had just been switched on.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 3300                                  # up ~55min, per the hazard timestamps
seq_set "$F" "0x51" 58; seq_set "$F" "0x53" 59        # RTC 01:53:51
seq_set "$F" "0x01" 60; seq_set "$F" "0x25" 61        # ...on day 25
seq_set "$F" "0x23" 32; seq_set "$F" "0x00" 33        # alarm2 21:00:23
seq_set "$F" "0x21" 34; seq_set "$F" "0x19" 35        # ...on day 19
export STUB_NOW="$INCIDENT_EPOCH"
run_watch "$F"
assert_contains "$RUN_OUT" '449608s' "the delta reproduces the field figure exactly"
assert_contains "$RUN_OUT" 'day 19 at 21:00:23 UTC' "and renders the appointment as the node did"
assert_contains "$RUN_OUT" 'it was OFF when that moment passed' "classified as a leftover — 449608s overdue cannot fit 3300s of uptime"
assert_eq "0" "$RUN_RC" "so it is NOT a hazard"
assert_eq "" "$(stub_log "$F" notify)" "and no priority-4 page happens"
assert_contains "$(stub_log "$F" systemctl)" 'wittypi-schedule.service' "the state is repaired instead"
unset STUB_NOW
fixture_rm "$F"

describe "the other signature: a delta that grows by exactly one tick interval"
# What a run of hazard lines carries, and what nothing was consuming. Recorded
# deltas of 446901, 447803, 448705, 449608, 450509 sit ~902s apart, which is
# the tick interval. A delta growing in lockstep with elapsed time while the
# appointment itself never changes is positive evidence that nothing is
# re-arming, as distinct from a single unlucky read. The watch acts on the
# first such tick rather than narrating a whole run of them.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 3300
seq_set "$F" "0x51" 58; seq_set "$F" "0x53" 59
seq_set "$F" "0x01" 60; seq_set "$F" "0x25" 61
seq_set "$F" "0x23" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x19" 35
export STUB_NOW="$INCIDENT_EPOCH"
run_watch "$F"; _t1=$(grep -c . "$F/repairs" 2>/dev/null || echo 0)
run_watch "$F"
run_watch "$F"
_asked=$(grep -c 'wittypi-schedule.service' "$F/log/systemctl" 2>/dev/null || echo 0)
assert_eq "3" "$_asked" "three ticks, three repair requests — then the cap"
run_watch "$F"
_asked=$(grep -c 'wittypi-schedule.service' "$F/log/systemctl" 2>/dev/null || echo 0)
assert_eq "3" "$_asked" "the fourth tick does NOT ask again"
assert_eq "1" "$RUN_RC" "and having given up, it becomes a hazard worth paging"
assert_contains "$RUN_OUT" 'repair attempts already made this boot' "saying so"
unset STUB_NOW
fixture_rm "$F"

describe "a leftover the scheduler cannot be asked to fix DOES page"
# Quiet is earned by the repair, not by the diagnosis. If the request fails
# the node really does have no shutdown appointment, and that must be said.
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 60
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35
export STUB_NOW=$(( RTC_EPOCH + 5 )) STUB_SYSTEMCTL_RC=1
run_watch "$F"
assert_eq "1" "$RUN_RC" "a hazard once the repair could not be requested"
assert_contains "$RUN_OUT" 'could not be re-run' "and it says the repair failed"
assert_contains "$(stub_log "$F" notify)" 'stale leftover' "paged"
unset STUB_NOW STUB_SYSTEMCTL_RC
fixture_rm "$F"

describe "alarm2 holding NO appointment is repaired before it is paged"
F=$(watch_fixture)
touch "$F/sched.env"
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x00" 34; seq_set "$F" "0x00" 35      # day 0 — never a valid appointment
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "no page while the repair is in flight"
assert_contains "$RUN_OUT" 'repair requested, verdict next tick' "the verdict is deferred, never assumed"
assert_contains "$(stub_log "$F" systemctl)" 'wittypi-schedule.service' "the scheduler was asked"
assert_eq "" "$(stub_log "$F" notify)" "nobody paged"
unset STUB_NOW
fixture_rm "$F"

describe "repair is BOUNDED — three attempts a boot, then it stops asking"
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 60
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35
printf '3\n' > "$F/repairs"
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "" "$(stub_log "$F" systemctl)" "no fourth request — a restart loop is not a repair"
assert_contains "$RUN_OUT" 'repair attempts already made this boot' "and it says why it stopped"
assert_eq "1" "$RUN_RC" "which makes it a hazard again: nothing is fixing this"
unset STUB_NOW
fixture_rm "$F"

describe "the kill switch: WITTYPI_WATCH_REPAIR=0 restores log-and-page"
F=$(watch_fixture)
touch "$F/sched.env"
set_uptime "$F" 60
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x21" 34; seq_set "$F" "0x13" 35
export STUB_NOW=$(( RTC_EPOCH + 5 )) WITTYPI_WATCH_REPAIR=0
run_watch "$F"
assert_eq "" "$(stub_log "$F" systemctl)" "nothing was asked to run"
assert_contains "$RUN_OUT" 'repair disabled' "and it is explicit about being switched off"
unset STUB_NOW WITTYPI_WATCH_REPAIR
fixture_rm "$F"

describe "day-of-month wrap: an appointment 23 'days behind' is NEXT month's, not missed"
F=$(watch_fixture)
touch "$F/sched.env"
seq_set "$F" "0x28" 61                                  # the RTC says day 28
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x23" 34; seq_set "$F" "0x05" 35          # alarm2 day 5 — early next month
export STUB_NOW=$(( $(date -u -d '2026-08-28 22:29:39' +%s) + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "the month-less pseudo-timestamp wraps; beyond half a month behind is future"
assert_contains "$RUN_OUT" 'alarm2 armed for day 05' "and it reads as armed"
unset STUB_NOW
fixture_rm "$F"

describe "alarm1 in the past is LOG-ONLY — the MCU's deferred re-fire self-heals it"
F=$(watch_fixture)
touch "$F/sched.env"
seq_set "$F" "0x00" 32; seq_set "$F" "0x00" 33
seq_set "$F" "0x23" 34; seq_set "$F" "0x13" 35          # alarm2 fine
seq_set "$F" "0x00" 27; seq_set "$F" "0x00" 28
seq_set "$F" "0x21" 29; seq_set "$F" "0x13" 30          # alarm1 90min behind
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "0" "$RUN_RC" "not a hazard"
assert_contains "$RUN_OUT" 'alarm1' "but noted"
assert_contains "$RUN_OUT" 're-fire' "with the mechanism that heals it"
assert_eq "" "$(stub_log "$F" notify)" "and nobody paged"
unset STUB_NOW
fixture_rm "$F"


describe "a flipped RTC Control_1 is a hazard — the 12-hour-mode bit that explained every RTC mystery"
F=$(watch_fixture)
seq_set "$F" "0x02" 54                                  # bit 1 = 12-hour mode
export STUB_NOW=$(( RTC_EPOCH + 5 ))
run_watch "$F"
assert_eq "1" "$RUN_RC" "a hazard"
assert_contains "$RUN_OUT" 'Control_1 reads 2' "with the read value"
assert_contains "$RUN_OUT" 'wittypi set 54 0' "and the live heal, spelled out"
assert_contains "$(stub_log "$F" notify)" 'Control_1' "paged"
unset STUB_NOW
fixture_rm "$F"

describe "configure owns register 54 — every boot re-asserts 24-hour mode"
assert_contains "$(cat "$RPI_UNITS_DIR/wittypi")" "wp_emit \"\$WP_REG_RTC_CTRL1\" 0" \
    "the policy row that heals a flipped mode bit at boot (needed MORE once the coin cell lands)"

# ── shape: the invariants a refactor must not lose ─────────────────────────

describe "the supervisor is a pure reader, structurally"
watch_body=$(grep -v '^\s*#' "$WATCH")
assert_not_contains "$watch_body" 'i2cset' "never touches i2cset"
assert_not_contains "$watch_body" 'wp_set' "never calls wp_set"
assert_not_contains "$watch_body" 'flock' "takes no lock — a reader must never starve ensure's 1s wait"
assert_not_contains "$watch_body" 'trap ' "no traps: SIGTERM must kill it in milliseconds"

describe "the unit's ordering direction — stop-before, so After=, never Before="
# Directives only: the header COMMENT deliberately discusses the rejected
# Before= (and the absent [Install]) by name, so the negative assertions must
# not read prose as configuration.
unit_text=$(grep -v '^#' "$WATCH_UNIT")
assert_contains "$unit_text" 'After=wittypi.service wake-guard.service' "After=wake-guard.service inverts to stop-first at shutdown"
assert_not_contains "$unit_text" 'Before=wake-guard' "Before= would run the arming ExecStop against a live tick holding the lock"
assert_contains "$unit_text" 'Conflicts=shutdown.target' "stopped early in the transition"
assert_not_contains "$unit_text" '[Install]' "timer-started: enabling it too would tick at boot's busiest moment"

describe "the unit's budget numbers are the ones the suite accounts for"
assert_contains "$unit_text" 'TimeoutStopSec=1' "1s stop bound — the fifth budget term"
assert_contains "$unit_text" 'TimeoutStartSec=10' "a tick is bounded"
assert_not_contains "$unit_text" 'RemainAfterExit' "RemainAfterExit would make OnUnitActiveSec a one-tick-per-boot timer — a blind supervisor"
assert_contains "$unit_text" 'EnvironmentFile=-/data/wittypi.env' "compares against the same intent configure applies"
watch_exec=$(grep '^ExecStart=' "$WATCH_UNIT")
assert_not_contains "$watch_exec" 'flock' "ExecStart is NOT lock-wrapped, unlike the boot-time units"

describe "the timer: quiet at boot, 15min cadence, no catch-up backlog"
timer_text=$(cat "$WATCH_TIMER")
assert_contains "$timer_text" 'OnBootSec=10min' "first tick well after the boot sequence settles"
assert_contains "$timer_text" 'OnUnitActiveSec=15min' "then every 15 minutes"
assert_contains "$timer_text" 'Persistent=false' "a long sleep leaves no missed-check backlog to fire"
assert_contains "$timer_text" 'WantedBy=timers.target' "enabled as a timer"

describe "the budget accounting knows the supervisor exists"
if have "$(dirname "$0")/duty-cycle.sh" "duty-cycle.sh — integration-only, it spans three layers"; then
assert_contains "$(cat "$(dirname "$0")/duty-cycle.sh")" 'wittypi-watch.service' "duty-cycle.sh derives the fifth term from the unit"
fi
assert_contains "$(cat "$RPI_DIR/timing-windows")" 'WATCH_SD' "timing-windows carries it too"
