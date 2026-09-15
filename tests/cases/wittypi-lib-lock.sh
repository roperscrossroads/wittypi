#!/bin/sh
# The library's lock, halt-marker and config-file helpers (WITTYPI-ACCESS-AUDIT
# §H1-H2 in csramsh-nodes). Contention cases use a REAL flock holder in
# another process, so what is proved is flock(2) semantics on this host, not a
# stub's idea of them.
#
# The child shells below are given single-quoted script text on purpose (it
# runs in the child, not here). SC2016 is file-scoped for that reason.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

LIB="$RPI_UNITS_DIR/wittypi-lib.sh"
command -v flock >/dev/null 2>&1 || { printf '  SKIP flock not on this host\n'; exit 0; }

# Every case runs the helper in a fresh child shell so a held fd 9 cannot leak
# between cases. $1 = fixture, $2 = script text; extra env via $3.
# $3 is a SPACE-SEPARATED list of NAME=value pairs for env, split on purpose.
child() { # shellcheck disable=SC2086
          env WITTYPI_LOCK="$1/lock" WITTYPI_RUN_DIR="$1/run" WITTYPI_UPTIME="$1/uptime" \
              WITTYPI_SITE_ENV="$1/site.env" WITTYPI_POLICY_ENV="$1/policy.env" ${3:-} \
              sh -c ". \"$LIB\"; $2" 2>&1; }
# Is the fixture's lock free right now, as seen from a third process?
lock_free() { flock -n "$1/lock" true 2>/dev/null; }

describe "wp_lock x takes the lock, wp_unlock frees it, and the file is appended to, never truncated"
F=$(fixture_new); printf 'keep\n' > "$F/lock"
out=$(child "$F" 'wp_lock x 1 t; echo rc=$?; flock -n "$WP_LOCK" true 2>/dev/null && echo FREE || echo HELD; echo mode=$WITTYPI_LOCK_HELD; wp_unlock; flock -n "$WP_LOCK" true 2>/dev/null && echo FREE || echo HELD; echo mode=${WITTYPI_LOCK_HELD:-unset}')
assert_contains "$out" "rc=0" "wp_lock x returns 0"
assert_eq "HELD FREE" "$(printf '%s\n' "$out" | grep -x 'HELD\|FREE' | tr '\n' ' ' | sed 's/ $//')" "held while locked, free after wp_unlock"
assert_contains "$out" "mode=x" "WITTYPI_LOCK_HELD names the mode while held"
assert_contains "$out" "mode=unset" "and is unset after wp_unlock"
assert_eq "keep" "$(cat "$F/lock")" "the lock file's content survives (opened for append)"
fixture_rm "$F"

describe "a contended exclusive lock: 75 after the wait, logged at err naming the caller, fd 9 closed"
F=$(fixture_new); : > "$F/lock"
flock -x "$F/lock" sleep 4 & HOLDER=$!
sleep 0.3
t0=$(date +%s)
out=$(child "$F" 'wp_lock x 1 "wake-guard keep"; echo rc=$?; readlink /proc/self/fd/9 >/dev/null 2>&1 && echo FD9-OPEN || echo FD9-CLOSED; echo mode=${WITTYPI_LOCK_HELD:-unset}' "INVOCATION_ID=x")
t1=$(date +%s)
assert_contains "$out" "rc=75" "returns 75"
assert_contains "$out" "<3>wittypi: wake-guard keep: could not get the I2C lock (x) within 1s" "the err line names the caller, the mode and the wait"
assert_contains "$out" "FD9-CLOSED" "fd 9 is closed again"
assert_contains "$out" "mode=unset" "nothing claims to hold it"
if [ $(( t1 - t0 )) -le 3 ]; then ok "gave up after about the wait (${t1}-${t0})"; else notok "gave up after the wait" "took $(( t1 - t0 ))s"; fi
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
fixture_rm "$F"

describe "shared readers coexist; a writer waits for them"
F=$(fixture_new); : > "$F/lock"
flock -s "$F/lock" sleep 4 & HOLDER=$!
sleep 0.3
out=$(child "$F" 'wp_lock s 1 reader; echo rc=$?')
assert_contains "$out" "rc=0" "wp_lock s succeeds beside another shared holder"
out=$(child "$F" 'wp_lock x 1 writer; echo rc=$?')
assert_contains "$out" "rc=75" "wp_lock x does not"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
fixture_rm "$F"

describe "nesting: a child of a holder neither blocks nor releases the parent's lock"
F=$(fixture_new); : > "$F/lock"
# The parent takes x, then runs a child that asks for s and for x, then checks
# the lock is STILL held after the child has exited.
out=$(child "$F" '
    wp_lock x 1 parent || exit 9
    sh -c ". \"'"$LIB"'\"; wp_lock s 1 child-s; echo child-s=\$?; wp_lock x 1 child-x; echo child-x=\$?; wp_unlock; echo child-done"
    flock -n "$WP_LOCK" true 2>/dev/null && echo AFTER-CHILD-FREE || echo AFTER-CHILD-HELD
    wp_unlock')
assert_contains "$out" "child-s=0" "s under an inherited x: covered, returns 0 at once"
assert_contains "$out" "child-x=0" "x under an inherited x: covered too"
assert_contains "$out" "AFTER-CHILD-HELD" "the child's wp_unlock did not release the parent's lock"
# s held by the parent, x asked for by the child: refused.
out=$(child "$F" '
    wp_lock s 1 parent || exit 9
    sh -c ". \"'"$LIB"'\"; wp_lock x 1 child-x; echo child-x=\$?"
    flock -n "$WP_LOCK" true 2>/dev/null && echo AFTER-CHILD-FREE || echo AFTER-CHILD-HELD
    wp_unlock' "INVOCATION_ID=x")
assert_contains "$out" "child-x=75" "x under an inherited s is refused with 75"
assert_contains "$out" "needs the I2C lock exclusive but inherits it shared" "and says why"
assert_contains "$out" "AFTER-CHILD-HELD" "the parent's shared lock is intact"
fixture_rm "$F"

describe "a stale WITTYPI_LOCK_HELD (fd 9 closed, or another file) does not count as holding"
F=$(fixture_new); : > "$F/lock"
flock -x "$F/lock" sleep 4 & HOLDER=$!
sleep 0.3
out=$(child "$F" 'WITTYPI_LOCK_HELD=x; export WITTYPI_LOCK_HELD; wp_lock x 1 t 9>&-; echo rc=$?')
assert_contains "$out" "rc=75" "the variable alone is not a lock: it queued and timed out"
out=$(child "$F" 'exec 9>>"$WP_LOCK.other"; WITTYPI_LOCK_HELD=x; export WITTYPI_LOCK_HELD; wp_lock x 1 t; echo rc=$?')
assert_contains "$out" "rc=75" "fd 9 on a different file is not the lock either"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
fixture_rm "$F"

describe "a holder that is SIGKILLed frees the lock"
# ONE process holds it (the shell execs into sleep, keeping fd 9), so the
# kill leaves no child behind with an inherited fd — `flock FILE CMD` would,
# and that child would keep the lock alive: the lock follows the fd, not the pid.
F=$(fixture_new); : > "$F/lock"
sh -c 'exec 9>>"$0"; flock -x 9; exec sleep 30' "$F/lock" & HOLDER=$!
sleep 0.3
out=$(child "$F" 'wp_lock x 0 t; echo rc=$?')
assert_contains "$out" "rc=75" "held before the kill (wait 0: one try)"
kill -9 "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out=$(child "$F" 'wp_lock x 1 t; echo rc=$?')
assert_contains "$out" "rc=0" "taken at once after the holder died"
fixture_rm "$F"

describe "a child started with 9>&- does not keep the lock alive after the caller exits"
F=$(fixture_new); : > "$F/lock"
out=$(child "$F" 'wp_lock x 1 t || exit 9; (sleep 2) 9>&- & echo started')
sleep 0.3
if lock_free "$F"; then ok "the lock is free while the 9>&- child still runs"; else notok "the lock is free while the 9>&- child still runs" "still held"; fi
fixture_rm "$F"

describe "usage errors are 2, and the exit-code names exist"
F=$(fixture_new); : > "$F/lock"
out=$(child "$F" 'wp_lock q 1 t; echo rc=$?; wp_lock x abc t; echo rc=$?; wp_lock x "" t; echo rc=$?; echo $WP_EX_LOCK $WP_EX_STANDDOWN')
assert_eq "rc=2 rc=2 rc=2" "$(printf '%s\n' "$out" | grep '^rc=' | tr '\n' ' ' | sed 's/ $//')" "mode q, wait abc, empty wait"
assert_contains "$out" "75 69" "WP_EX_LOCK=75, WP_EX_STANDDOWN=69"
fixture_rm "$F"

describe "the halt marker: written atomically, read back, updated, stale after 120 s, cleared"
F=$(fixture_new); printf '500.12 900.00\n' > "$F/uptime"
out=$(child "$F" 'wp_halt_write daemon "scheduled shutdown (alarm2)" pending "day 15 22:30" "day 15 22:27"; echo rc=$?; wp_halt_read; echo; wp_halt_requested && echo REQUESTED')
assert_contains "$out" "rc=0" "written"
assert_contains "$out" "source=daemon" "source"
assert_contains "$out" "uptime=500" "uptime, whole seconds"
assert_contains "$out" "reason=scheduled shutdown (alarm2)" "reason"
assert_contains "$out" "state=pending" "state"
assert_contains "$out" "a1=day 15 22:30" "a1"
assert_contains "$out" "a2=day 15 22:27" "a2"
assert_contains "$out" "REQUESTED" "wp_halt_requested is true"
assert_eq "" "$(find "$F/run" -name '*tmp*')" "no temporary file left behind"
out=$(child "$F" 'wp_halt_update state armed; echo rc=$?; wp_halt_read | grep -c "^state="; wp_halt_read | grep "^state="')
assert_contains "$out" "rc=0" "updated"
assert_contains "$out" "state=armed" "the key is rewritten"
assert_eq "1" "$(printf '%s\n' "$out" | sed -n 2p)" "and appears once"
printf '621.00 900.00\n' > "$F/uptime"
out=$(child "$F" 'wp_halt_read; echo rc=$?; wp_halt_requested || echo NOT-REQUESTED; [ -f "$WP_HALT_MARKER" ] || echo GONE')
assert_contains "$out" "rc=1" "121 s later it is stale: read returns 1"
assert_contains "$out" "halt marker from uptime 500s is stale at 621s — removing it" "logged"
assert_contains "$out" "GONE" "and deleted"
assert_contains "$out" "NOT-REQUESTED" "wp_halt_requested is false"
out=$(child "$F" 'wp_halt_read; echo rc=$?; wp_halt_update state x; echo rc=$?')
assert_eq "rc=1 rc=1" "$(printf '%s\n' "$out" | grep '^rc=' | tr '\n' ' ' | sed 's/ $//')" "no marker: read 1, update 1, silently"
printf '10.00 900.00\n' > "$F/uptime"
out=$(child "$F" 'wp_halt_write gate poweroff; wp_halt_requested && echo R1; wp_halt_clear; wp_halt_requested || echo CLEARED')
assert_contains "$out" "R1" "a fresh marker"
assert_contains "$out" "CLEARED" "wp_halt_clear removes it"
out=$(child "$F" 'printf "source=x\nuptime=200\n" > "$WP_HALT_MARKER"; wp_halt_read; echo rc=$?')
assert_contains "$out" "rc=1" "a marker from a LATER uptime than now (a different boot) is stale too"
fixture_rm "$F"

describe "wp_env_val: last assignment wins, quotes stripped, never executed, WITTYPI_ names only"
F=$(fixture_new)
printf 'WITTYPI_GUARANTEED_WAKE=26\n# c\nWITTYPI_TZ_NOTE="ET:-4/-5"\nWITTYPI_GUARANTEED_WAKE=16\nWITTYPI_EVIL=$(touch %s/RAN)\nPATH=/bad\n' "$F" > "$F/site.env"
out=$(child "$F" 'wp_env_val "$WITTYPI_SITE_ENV" WITTYPI_GUARANTEED_WAKE; echo; wp_env_val "$WITTYPI_SITE_ENV" WITTYPI_TZ_NOTE; echo; wp_env_val "$WITTYPI_SITE_ENV" WITTYPI_EVIL; echo; wp_env_val "$WITTYPI_SITE_ENV" PATH; echo rc=$?; wp_env_val "$WITTYPI_SITE_ENV" WITTYPI_MISSING; echo rc=$?; wp_env_val "$F/none" WITTYPI_X; echo rc=$?; wp_env_val "$WITTYPI_SITE_ENV" "WITTYPI_A;rm"; echo rc=$?')
assert_eq "16" "$(printf '%s\n' "$out" | sed -n 1p)" "last wins (26 then 16 → 16)"
assert_eq "ET:-4/-5" "$(printf '%s\n' "$out" | sed -n 2p)" "one pair of quotes stripped"
assert_eq "\$(touch $F/RAN)" "$(printf '%s\n' "$out" | sed -n 3p)" "a command in a value is text"
assert_file_absent "$F/RAN" "and was not run"
assert_eq "rc=2 rc=1 rc=1 rc=2" "$(printf '%s\n' "$out" | grep '^rc=' | tr '\n' ' ' | sed 's/ $//')" "PATH → 2; absent line → 1; absent file → 1; a name with punctuation → 2"
fixture_rm "$F"

describe "wp_guaranteed_wake_policy: policy file > environment > site file > nothing"
F=$(fixture_new)
printf 'WITTYPI_GUARANTEED_WAKE=26\n' > "$F/site.env"
out=$(child "$F" 'wp_guaranteed_wake_policy; echo " rc=$?"')
assert_eq "26	site rc=0" "$out" "only the site file: its value, source site"
out=$(child "$F" 'wp_guaranteed_wake_policy; echo " rc=$?"' "WITTYPI_GUARANTEED_WAKE=20")
assert_eq "20	env rc=0" "$out" "the environment beats the site file"
printf 'WITTYPI_GUARANTEED_WAKE=16\n' > "$F/policy.env"
out=$(child "$F" 'wp_guaranteed_wake_policy; echo " rc=$?"' "WITTYPI_GUARANTEED_WAKE=20")
assert_eq "16	policy rc=0" "$out" "the policy file beats both (it floors the site value)"
out=$(child "$F" 'wp_guaranteed_wake_policy; echo " rc=$?"' "WITTYPI_POLICY_ENV=/dev/null WITTYPI_GUARANTEED_WAKE=20")
assert_eq "20	env rc=0" "$out" "WITTYPI_POLICY_ENV=/dev/null ignores the policy file (a bench override)"
rm -f "$F/site.env" "$F/policy.env"
out=$(child "$F" 'wp_guaranteed_wake_policy; echo " rc=$?"')
assert_eq " rc=1" "$out" "nothing anywhere: no output, 1"
fixture_rm "$F"

describe "the helpers' defaults are the production paths"
out=$(sh -c ". \"$LIB\"; echo \$WP_LOCK \$WP_RUN_DIR \$WP_HALT_MARKER \$WP_POLICY_ENV \$WP_UPTIME_FILE \$WP_HALT_STALE_SEC")
assert_eq "/run/wittypi.lock /run/wittypi /run/wittypi/halt-requested /run/wittypi/policy.env /proc/uptime 120" "$out" "lock, run dir, marker, policy file, uptime source, staleness"
