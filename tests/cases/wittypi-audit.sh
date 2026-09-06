#!/bin/sh
# wittypi-audit — the human-facing report. The real script runs against a
# stub `wittypi` CLI, a stub wake-guard, and the same
# i2c sequence stubs the lib tests use (the audit sources wittypi-lib.sh for
# wp_present / wp_check_guaranteed_wake / the board registry — the SHARED
# verdicts are the point, so the shared code paths are what gets exercised).
#
# The stubs are GENERATED shell; single quotes are the point (SC2016).
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

AUDIT="$OPS_UNITS_DIR/wittypi-audit"
LIB="$RPI_UNITS_DIR/wittypi-lib.sh"

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

RTC_TIME='2026-08-13 22:29:39'
RTC_EPOCH=$(date -u -d "$RTC_TIME" +%s)

# A fixture where the audit has a healthy, idle node to describe. The stub
# `wittypi` answers the three subcommands the audit uses; alarm2 registers
# come from STUB_A2_* so each case can arm or clear them.
audit_fixture() {
    _af=$(fixture_new)
    stub_i2c_seq "$_af"; stub_date "$_af"
    seq_set "$_af" "0x26" 0
    seq_set "$_af" "0x1a" 49
    {
        printf '#!/bin/sh\n'
        printf 'case "$1" in\n'
        printf '    status) echo "firmware id 0x26 revision 7 (stub)" ;;\n'
        printf '    rtc) [ "${STUB_RTC_FAIL:-0}" = 1 ] && exit 1\n'
        printf '         echo "${STUB_RTC:-2026-08-13 22:29:39}" ;;\n'
        printf '    get) case "$2" in\n'
        printf '             32) echo "${STUB_A2_SEC:-0}" ;;\n'
        printf '             33) echo "${STUB_A2_MIN:-0}" ;;\n'
        printf '             34) echo "${STUB_A2_HOUR:-0}" ;;\n'
        printf '             35) echo "${STUB_A2_DAY:-0}" ;;\n'
        printf '             *) echo 0 ;;\n'
        printf '         esac ;;\n'
        printf 'esac\n'
    } > "$_af/bin/wittypi"
    {
        printf '#!/bin/sh\n'
        printf '[ "${STUB_WG_STATE:-1}" = 0 ] && echo "wake-guard: wake armed: day 16 at 18:04:15 UTC" >&2\n'
        printf 'exit "${STUB_WG_STATE:-1}"\n'
    } > "$_af/bin/wake-guard"
    chmod +x "$_af/bin/wittypi" "$_af/bin/wake-guard"
    printf 'WITTYPI_GUARANTEED_WAKE=26\n' > "$_af/data/wittypi.env"
    touch "$_af/synced"
    printf '%s' "$_af"
}

run_audit() {
    RUN_OUT=$(
        PATH="$1/bin:$PATH" \
        WITTYPI_AUDIT_LIB="$LIB" \
        WITTYPI_AUDIT_WITTYPI="$1/bin/wittypi" \
        WITTYPI_AUDIT_WAKE_GUARD="$1/bin/wake-guard" \
        WITTYPI_AUDIT_ENV="$1/data/wittypi.env" \
        WITTYPI_AUDIT_SCHEDULE="$1/data/wittypi-schedule.env" \
        WITTYPI_AUDIT_RECORD="$1/data/watch-hazards" \
        WITTYPI_AUDIT_SYNCED="$1/synced" \
        sh "$AUDIT" 2>&1
    )
    RUN_RC=$?
    return 0
}

describe "a healthy idle node, on one screen"
F=$(audit_fixture)
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=unregistered-test
run_audit "$F"
assert_eq "0" "$RUN_RC" "the report succeeds"
assert_contains "$RUN_OUT" 'firmware id 0x26 revision 7 (stub)' "controller identity comes from wittypi status"
assert_contains "$RUN_OUT" '3s from the NTP-synced clock' "the RTC is compared, not just printed"
assert_contains "$RUN_OUT" 'not armed — fine while up' "alarm1 idle is explained, not alarmed about"
assert_contains "$RUN_OUT" 'no shutdown scheduled' "alarm2 clear reads as clear"
assert_contains "$RUN_OUT" 'register 49 = 26 — matches the site policy' "guaranteed wake compared against /data intent WITHOUT the audit being a unit"
assert_contains "$RUN_OUT" 'HAND-SCHEDULED mode' "the scheduler section is honest about no duty cycle being configured"
assert_contains "$RUN_OUT" 'hazards     none recorded' "and the supervisor record is clean"
assert_contains "$RUN_OUT" 'timing-windows' "the budget axis is pointed at, not duplicated"
unset STUB_NOW WITTYPI_BOARD_ID
fixture_rm "$F"

describe "an armed wake is reported in wake-guard's own words"
F=$(audit_fixture)
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t STUB_WG_STATE=0
run_audit "$F"
assert_contains "$RUN_OUT" 'ARMED — wake armed: day 16 at 18:04:15 UTC' "the tri-state's own describe line, no reimplementation"
unset STUB_NOW WITTYPI_BOARD_ID STUB_WG_STATE
fixture_rm "$F"

describe "a scheduled shutdown decodes from the registers only this tool surfaces"
F=$(audit_fixture)
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t
export STUB_A2_SEC=21 STUB_A2_MIN=83 STUB_A2_HOUR=23 STUB_A2_DAY=22
run_audit "$F"
assert_contains "$RUN_OUT" 'SHUTDOWN scheduled: day 16 at 17:53:15 UTC' "raw 22/23/83/21 decodes as BCD, day-validated"
unset STUB_NOW WITTYPI_BOARD_ID STUB_A2_SEC STUB_A2_MIN STUB_A2_HOUR STUB_A2_DAY
fixture_rm "$F"

describe "guaranteed-wake drift and disablement render as the shared verdicts"
F=$(audit_fixture)
seq_set "$F" "0x14" 49
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t
run_audit "$F"
assert_contains "$RUN_OUT" 'DRIFTED — register 49 reads 20, site policy says 26' "drift names both numbers"
seq_set "$F" "0x00" 49
run_audit "$F"
assert_contains "$RUN_OUT" 'DISABLED — register 49 is 0' "zero is the loud verdict, same as the supervisor's"
unset STUB_NOW WITTYPI_BOARD_ID
fixture_rm "$F"

describe "the supervisor's record is surfaced with a count, newest last"
F=$(audit_fixture)
for i in 1 2 3 4 5 6 7; do
    printf '2026-08-16 12:00:0%s  hazard number %s\n' "$i" "$i" >> "$F/data/watch-hazards"
done
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t
run_audit "$F"
assert_contains "$RUN_OUT" '!! 7 recorded' "the count is the headline"
assert_contains "$RUN_OUT" 'hazard number 7' "the newest entry is shown"
assert_not_contains "$RUN_OUT" 'hazard number 1' "and the oldest is not — last 5 only"
unset STUB_NOW WITTYPI_BOARD_ID
fixture_rm "$F"

describe "no controller: say so and exit 1 — an audit of nothing is not a report"
F=$(fixture_new); stub_i2c_seq "$F"; stub_date "$F"
export WITTYPI_BOARD_ID=t
run_audit "$F"
assert_eq "1" "$RUN_RC" "exit 1 with no controller"
assert_contains "$RUN_OUT" 'nothing to audit' "and the reason is stated"
unset WITTYPI_BOARD_ID
fixture_rm "$F"

describe "the audit is a pure reader, structurally — same bar as the supervisor"
audit_body=$(grep -v '^\s*#' "$AUDIT")
assert_not_contains "$audit_body" 'i2cset' "never touches i2cset"
assert_not_contains "$audit_body" 'wp_set' "never calls wp_set"
assert_not_contains "$audit_body" 'flock' "takes no lock"
assert_not_contains "$audit_body" 'trap ' "no traps"

describe "the recipe ships it where humans type"
# The packaging recipe lives in the meta-wittypi layer repo, not this one;
# WITTYPI_YOCTO_OPS_RECIPE points an integration build at it, and absent that
# this SKIPs by name. Same convention as WITTYPI_YOCTO_RECIPE elsewhere.
OPS_BB="${WITTYPI_YOCTO_OPS_RECIPE:-}"
if have "$OPS_BB" "wittypi-ops_1.0.bb (meta-wittypi layer)"; then
assert_contains "$(cat "$OPS_BB")" '${bindir}/wittypi-audit' \
    "wittypi-ops installs the audit into bindir"
fi

# ── the intended-vs-armed delta ────────────────────────────────────────────

describe "a configured schedule with NO armed alarm2 is flagged in the report"
F=$(audit_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=720\nWITTYPI_SCHEDULE_OFF_SEC=6480\n' > "$F/data/wittypi-schedule.env"
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t
run_audit "$F"
assert_contains "$RUN_OUT" 'WITTYPI_SCHEDULE_ON_SEC=720' "the config is shown"
assert_contains "$RUN_OUT" 'NO shutdown appointment' "and the missing alarm2 is the verdict"
assert_contains "$RUN_OUT" 'wittypi-schedule.service' "pointing at the unit to check"
unset STUB_NOW WITTYPI_BOARD_ID
fixture_rm "$F"

describe "a past alarm2 under a schedule reads as the missed shutdown it is"
F=$(audit_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=720\nWITTYPI_SCHEDULE_OFF_SEC=6480\n' > "$F/data/wittypi-schedule.env"
# day 13 21:00:00 against an RTC of 22:29:39 — decimal of the BCD bytes,
# because the stub CLI answers like the real `wittypi get` does
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t STUB_A2_DAY=19 STUB_A2_HOUR=33
run_audit "$F"
assert_contains "$RUN_OUT" 'SHUTDOWN scheduled: day 13 at 21:00:00 UTC' "the appointment decodes"
assert_contains "$RUN_OUT" 'in the PAST' "and the delta names it missed"
unset STUB_NOW WITTYPI_BOARD_ID STUB_A2_DAY STUB_A2_HOUR
fixture_rm "$F"

describe "a future alarm2 under a schedule reads as consistent"
F=$(audit_fixture)
printf 'WITTYPI_SCHEDULE_ON_SEC=720\nWITTYPI_SCHEDULE_OFF_SEC=6480\n' > "$F/data/wittypi-schedule.env"
export STUB_NOW=$(( RTC_EPOCH + 3 )) WITTYPI_BOARD_ID=t STUB_A2_DAY=19 STUB_A2_HOUR=35
run_audit "$F"
assert_contains "$RUN_OUT" 'SHUTDOWN scheduled: day 13 at 23:00:00 UTC' "the appointment decodes"
assert_contains "$RUN_OUT" 'consistent with a running schedule' "and the delta agrees"
unset STUB_NOW WITTYPI_BOARD_ID STUB_A2_DAY STUB_A2_HOUR
fixture_rm "$F"
