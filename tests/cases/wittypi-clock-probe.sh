#!/bin/sh
# rtc-sync waits, bounded, for a controller that does not answer yet, and says
# why it did not.
#
# On 2026-09-15 wittypi-clock found no controller in 7 of 10 boots at ~28 s,
# while wittypi-configure found it ~2 s later and 400 steady-state reads were
# clean. The clock then stayed at the last saved time until NTP, and the log
# said only "no Witty Pi" because wp_get discards i2cget's stderr.
#
# The stubs below are written with printf and single-quoted shell text on
# purpose: that text is the stub script, not something to expand here.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

# i2cget stub: register 0 FAILS (rc 1, a message on stderr, like i2c-tools on a
# NAK) for the first $F/fails calls, then answers 0x26 (or $F/id). The RTC block
# answers a fixed August time. Every call is logged.
stub_probe() {
    mkdir -p "$1/bin"
    printf '%s\n' "${2:-0}" > "$1/fails"
    {
        printf '#!/bin/sh\n'
        printf 'echo "$4" >> "%s/log/i2cget"\n' "$1"
        printf 'if [ "$4" = 0 ]; then\n'
        printf '  n=$(cat "%s/fails")\n' "$1"
        printf '  if [ "$n" -gt 0 ]; then echo $((n-1)) > "%s/fails"; echo "Error: Read failed" >&2; exit 1; fi\n' "$1"
        printf '  if [ -f "%s/id" ]; then cat "%s/id"; else echo 0x26; fi; exit 0\n' "$1" "$1"
        printf 'fi\n'
        printf 'case "$4" in 58) echo 0x39;; 59) echo 0x29;; 60) echo 0x22;; 61) echo 0x13;; 62) echo 0x03;; 63) echo 0x08;; 64) echo 0x26;; *) echo 0x00;; esac\n'
    } > "$1/bin/i2cget"
    printf '#!/bin/sh\necho "$*" >> "%s/log/sleep"\n' "$1" > "$1/bin/sleep"
    # date: RTC epoch 2000 (newer) than now 1000, and -s records a SET.
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '  *-s*)  echo SET >> "%s/log/date-set"; exit 0 ;;\n' "$1"
        printf '  *-d*)  echo 2000 ;;\n'
        printf '  *+%%s*) echo 1000 ;;\n'
        printf '  *)     echo stub-now ;;\n'
        printf 'esac\n'
    } > "$1/bin/date"
    : > "$1/dev-i2c-1"
    chmod +x "$1/bin/i2cget" "$1/bin/sleep" "$1/bin/date"
}
clock() { # <fixture> <probe-sec>
    RUN_OUT=$(PATH="$1/bin:$PATH" WITTYPI_LIB="$RPI_UNITS_DIR/wittypi-lib.sh" \
        WITTYPI_I2C_DEV="$1/dev-i2c-1" WITTYPI_PROBE_SEC="$2" INVOCATION_ID=x \
        WITTYPI_LOCK="$1/lock" WITTYPI_RUN_DIR="$1/run" \
        sh "$RPI_UNITS_DIR/wittypi" rtc-sync 2>&1)
    RUN_RC=$?
}
sleeps() { grep -c . "$1/log/sleep" 2>/dev/null || echo 0; }

describe "a controller that answers on the third attempt: waited for, clock set, cause logged"
F=$(fixture_new); stub_probe "$F" 3
clock "$F" 15
assert_eq "0" "$RUN_RC" "exits 0"
assert_contains "$RUN_OUT" "did not answer on attempt 1: i2cget failed (rc 1): Error: Read failed" "logs the real i2cget error of the first miss"
assert_contains "$RUN_OUT" "controller answered on attempt 3" "and on which attempt it answered"
assert_contains "$RUN_OUT" "system clock set from RTC" "the clock is set"
assert_eq "2" "$(sleeps "$F")" "slept once between each attempt"
assert_not_contains "$RUN_OUT" "no Witty Pi at" "no 'not fitted' message"
fixture_rm "$F"

describe "a controller that never answers: bounded, then the old message and exit 1, at err"
F=$(fixture_new); stub_probe "$F" 1000
clock "$F" 3
assert_eq "1" "$RUN_RC" "exits 1 (no controller)"
assert_eq "3" "$(sleeps "$F")" "tried for the bound: 4 attempts, 3 sleeps"
assert_contains "$RUN_OUT" "<3>wittypi: no controller after 4 attempt(s); first miss: i2cget failed" "an err-level line with both causes"
assert_contains "$RUN_OUT" "no Witty Pi at 0x08 on i2c-1." "the human-readable message is unchanged"
assert_eq "" "$(cat "$F/log/date-set" 2>/dev/null)" "the clock is not set"
fixture_rm "$F"

describe "at a prompt (no probe bound): one attempt, no wait"
F=$(fixture_new); stub_probe "$F" 1000
clock "$F" ""
assert_eq "1" "$RUN_RC" "exits 1"
assert_eq "0" "$(sleeps "$F")" "never sleeps"
F2=$(fixture_new); stub_probe "$F2" 1000
clock "$F2" "15s"
assert_eq "0" "$(sleeps "$F2")" "a malformed bound is a single attempt, never a hang"
fixture_rm "$F"; fixture_rm "$F2"

describe "the cause names what actually happened"
F=$(fixture_new); stub_probe "$F" 1000; rm -f "$F/dev-i2c-1"
clock "$F" 0
assert_contains "$RUN_OUT" "dev-i2c-1 does not exist" "a missing adapter"
fixture_rm "$F"
F=$(fixture_new); stub_probe "$F" 0; echo 0x00 > "$F/id"
clock "$F" 1
assert_contains "$RUN_OUT" "id register reads 0x00, expected 0x26" "a wrong id"
fixture_rm "$F"

describe "the clock unit asks for the wait, and its start timeout covers it"
u=$(cat "$RPI_SYSTEMD_DIR/wittypi-clock.service")
assert_contains "$u" "Environment=WITTYPI_PROBE_SEC=15" "WITTYPI_PROBE_SEC=15"
probe=$(printf '%s\n' "$u" | sed -n 's/^Environment=WITTYPI_PROBE_SEC=//p')
start=$(printf '%s\n' "$u" | sed -n 's/^TimeoutStartSec=//p')
lockw=$(printf '%s\n' "$u" | sed -n 's/^Environment=WITTYPI_LOCK_WAIT=//p')
assert_contains "$u" "ExecStart=/usr/bin/wittypi rtc-sync" "ExecStart is the bare tool: it takes the lock itself, after the probe"
assert_eq "15" "$lockw" "WITTYPI_LOCK_WAIT=15"
assert_not_contains "$(printf '%s\n' "$u" | grep -v '^#')" "flock" "no flock wrapper"
sync_body=$(sed -n '/^rtc-sync)/,/^rtc-write)/p' "$RPI_UNITS_DIR/wittypi")
probe_ln=$(printf '%s\n' "$sync_body" | grep -n 'wp_wait_present' | cut -d: -f1 | head -n 1)
lock_ln=$(printf '%s\n' "$sync_body" | grep -n 'wp_cli_lock s 15' | cut -d: -f1 | head -n 1)
if [ -n "$probe_ln" ] && [ -n "$lock_ln" ] && [ "$probe_ln" -lt "$lock_ln" ]; then
    ok "rtc-sync probes for the controller BEFORE it takes the lock (lines $probe_ln < $lock_ln)"
else
    notok "rtc-sync probes before it locks" "probe at ${probe_ln:-none}, lock at ${lock_ln:-none}"
fi
if [ -n "$start" ] && [ -n "$probe" ] && [ "$start" -ge $(( ${lockw:-0} + probe + 10 )) ]; then
    ok "TimeoutStartSec $start >= lock ${lockw:-0} + probe $probe + 10 for the RTC read"
else
    notok "TimeoutStartSec covers lock + probe + RTC read" "start=$start lock=$lockw probe=$probe"
fi
