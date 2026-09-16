#!/bin/sh
# timing-windows' shutdown budget is TWO sums, one per path, never one.
#
# Until 2026-09-16 check 1 added the controller path's caps (the daemon's
# wake-guard run, the notify, the mark-good grace) onto the shutdown term of
# the OTHER path (poweroff.real, nothing armed) and, once the terms were
# re-measured, printed 25 >= 25 against a controller path measured at
# 12.8-14.5 s. This case pins the per-path sums, the worst-case verdict, and
# that each path fails on its own.
#
# The report is run from a scratch copy of the repo so the terms file beside
# it can be rewritten; a fixture notify-state and wake-guard.service give the
# caps that the site layer owns (2 s and 5 s), as the integrator's tree would.
. "$(dirname "$0")/../lib.sh"

W=$(mktemp -d "${TMPDIR:-/tmp}/tw-test.XXXXXX") || exit 1
( cd "$RPI_DIR" && tar cf - --exclude=.git --exclude=build --exclude=tests . ) | ( cd "$W" && tar xf - )
cat > "$W/notify-state" <<'NS'
#!/bin/sh
: "${NOTIFY_STATE_SHUTDOWN_TIMEOUT:-2}"
NS
printf '[Service]\nTimeoutStopSec=5\nExecStop=/usr/libexec/site/wake-guard stop\n' > "$W/systemd/wake-guard.service"
cp "$RPI_DIR/timing-terms" "$W/timing-terms"

tw() { OUT=$(sh "$W/timing-windows" --no-live 2>"$W/err"); RC=$?; ERR=$(cat "$W/err"); }
set_term() { sed -i "s/^$1=[0-9]*$/$1=$2/" "$W/timing-terms"; }

describe "the shipped terms: both paths fit, and the verdict names the tighter one"
tw
assert_contains "$OUT" "path A, wake armed: watch + wake-guard + notify + grace + shutdown(armed) < power-cut: 1 + 5 + 2 + 8 + 7 = 23 < 25s" "path A sums the caps onto the ARMED shutdown"
assert_contains "$OUT" "path B, nothing armed: watch + shutdown(unarmed) < power-cut: 1 + 9 = 10 < 25s" "path B is the watch and the unarmed shutdown alone"
assert_contains "$OUT" "worst case is path A: 2s of slack" "the verdict is the path with the least slack"
assert_contains "$OUT" "but only 2s of slack on path A, against T_shutdown_armed measured at 7s" "the headroom advice keys off that path's term"
assert_not_contains "$OUT" "grace + shutdown <" "the one-sum line is gone"
assert_not_contains "$OUT" "grace + shutdown >=" "and so is its hazard"
assert_contains "$OUT" "T_shutdown_armed" "the table shows the armed term"

describe "path B fails on its own: the unarmed shutdown alone reaches the cut"
set_term T_SHUTDOWN 24; tw
assert_contains "$OUT" "HAZARD path B, nothing armed: watch + shutdown(unarmed) >= power-cut: 1 + 24 = 25 >= 25s" "path B is a hazard at equality"
assert_contains "$OUT" "path A, wake armed: watch + wake-guard + notify + grace + shutdown(armed) < power-cut: 1 + 5 + 2 + 8 + 7 = 23 < 25s" "path A is untouched by it"
assert_contains "$OUT" "worst case is path B: 0s of slack" "the verdict moves to B"
set_term T_SHUTDOWN 9

describe "path A fails on its own: the caps plus the armed shutdown reach the cut"
set_term T_SHUTDOWN_ARMED 9; tw
assert_contains "$OUT" "HAZARD path A, wake armed: watch + wake-guard + notify + grace + shutdown(armed) >= power-cut: 1 + 5 + 2 + 8 + 9 = 25 >= 25s" "path A is a hazard at equality"
assert_contains "$OUT" "the CONTROLLER path" "and says which path that is"
assert_contains "$OUT" "path B, nothing armed: watch + shutdown(unarmed) < power-cut: 1 + 9 = 10 < 25s" "path B is untouched by it"
set_term T_SHUTDOWN_ARMED 7

describe "a terms file without the armed term stops the report rather than guessing"
sed -i '/^T_SHUTDOWN_ARMED=/d' "$W/timing-terms"; tw
assert_eq 3 "$RC" "exit 3"
assert_contains "$ERR" "timing-terms is missing T_SHUTDOWN_ARMED" "names the term"

rm -rf "$W"
