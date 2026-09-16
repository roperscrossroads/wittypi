#!/bin/sh
# wittypi-daemon: the request path (WITTYPI-ACCESS-AUDIT.md §H2, D9, D14).
#
# What is asserted, and why each matters:
#   * a controller that is slow to answer at boot is waited for, bounded —
#     one miss must not cost SYS_UP and the rail cut for the whole boot (D14);
#   * an absent controller still exits 0, after the bound, and says how long
#     it looked;
#   * the halt marker exists, with source/state/reason, BEFORE the wake hook
#     runs — that marker is what makes every other writer stand down;
#   * the wake hook runs with TERM ignored, so a stop job already under way
#     cannot interrupt the pre-arm (D9);
#   * the daemon still reaches poweroff;
#   * the unit bounds its stop at 10 s, the pre-arm's budget.
#
# Stubs are generated shell: the single quotes keep $(...) for the stub.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

DAEMON="$RPI_UNITS_DIR/wittypi-daemon"
UNIT="$RPI_UNITS_DIR/systemd/wittypi.service"

# gpio stubs: a healthy halt line, an unclaimed pin, an edge that fires at once.
stub_gpio_ok() {
    printf '#!/bin/sh\necho "gpiochip0 [pinctrl-bcm2835] (54 lines)"\n' > "$1/bin/gpiodetect"
    printf '#!/bin/sh\necho 1\n' > "$1/bin/gpioget"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log/gpioset"\nexit 0\n' "$1" > "$1/bin/gpioset"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/gpiomon"
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/gpioinfo"
    chmod +x "$1/bin/gpiodetect" "$1/bin/gpioget" "$1/bin/gpioset" "$1/bin/gpiomon" "$1/bin/gpioinfo"
    touch "$1/dev-i2c"
}
# i2cget pops one value per call from $F/seq/<reg>, repeating the last once
# exhausted. Register 11 answers 2 (alarm2), 12 answers 7 (firmware rev).
stub_i2c_seq() {
    mkdir -p "$1/seq"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$4" >> "%s/log/i2cget"\n' "$1"
        printf 'f="%s/seq/$4"\n' "$1"
        printf '[ -f "$f" ] || { case "$4" in 11) echo 0x02;; 12) echo 0x07;; *) echo 0x00;; esac; exit 0; }\n'
        printf 'v=$(sed -n 1p "$f")\n'
        printf 'sed -i 1d "$f" 2>/dev/null\n'
        printf '[ -s "$f" ] || printf "%%s\\n" "$v" > "$f"\n'
        printf 'printf "%%s\\n" "$v"\n'
    } > "$1/bin/i2cget"
    chmod +x "$1/bin/i2cget"
}
# shellcheck disable=SC2086
seq_set() { printf '%s\n' $2 > "$1/seq/$3"; }
# sleep advances the fixture clock by n seconds and counts.
stub_ticking_sleep() {
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/sleep"\n' "$1"
        printf 'cur=$(cut -d" " -f1 "%s/proc/uptime" | cut -d. -f1)\n' "$1"
        printf 'printf "%%s.00 2000.00\\n" "$(( cur + ${1:-1} ))" > "%s/proc/uptime"\n' "$1"
    } > "$1/bin/sleep"
    chmod +x "$1/bin/sleep"
}
daemon_fixture() {
    F=$(fixture_new)
    stub_gpio_ok "$F"; stub_i2c_seq "$F"; stub_ticking_sleep "$F"
    stub "$F" systemctl "exit 0"
    mkdir -p "$F/run"
    seq_set "$F" "0x26" 0
}
run_daemon() {
    WITTYPI_I2C_DEV="$F/dev-i2c" WITTYPI_GATE="$F/no-such-gate" \
    WITTYPI_NOTIFY_STATE="${1:-$F/no-such-notify}" WITTYPI_WAKE_GUARD="${2:-$F/no-such-guard}" \
    WITTYPI_HALT_SETTLE_SEC=15 WITTYPI_DAEMON_PROBE_TRIES="${WITTYPI_DAEMON_PROBE_TRIES:-10}" \
        run_rpi_unit "$F" wittypi-daemon
}

describe "the shipped pieces exist"
assert_file_exists "$DAEMON" "wittypi-daemon"
assert_file_exists "$UNIT" "wittypi.service"

# ── D14: a controller that answers late is waited for ──────────────────────
describe "a controller that fails two probes and then answers still gets SYS_UP"
daemon_fixture
seq_set "$F" "0x00 0x00 0x00 0x00 0x26 0x26" 0     # probe 1 and 2 agree on 0x00; probe 3 is the id
run_daemon
assert_eq "0" "$RUN_RC" "exit 0"
assert_contains "$RUN_OUT" "did not answer on probe 1" "the first miss is logged, with what was read"
assert_contains "$RUN_OUT" "answered on probe 3" "and the probe that succeeded is named"
assert_contains "$RUN_OUT" "signalling SYS_UP" "SYS_UP is sent"
assert_eq "1" "$(stub_log "$F" gpioset | grep -c 'gpiochip0')" "exactly one gpioset pulse train"
assert_contains "$RUN_OUT" "powering off" "and the request path runs through to poweroff"
fixture_rm "$F"

describe "a controller that never answers is 'not fitted' after the bound, exit 0, no SYS_UP"
daemon_fixture
seq_set "$F" "0x00" 0
WITTYPI_DAEMON_PROBE_TRIES=3 run_daemon
assert_eq "0" "$RUN_RC" "exit 0 — a bench Pi with no board is not a failed unit"
assert_contains "$RUN_OUT" "after 3 probes" "says how long it looked"
assert_contains "$RUN_OUT" "not fitted" "and what it concluded"
assert_eq "2" "$(stub_log "$F" sleep | wc -l | tr -d ' ')" "slept between probes, and only between them"
assert_eq "" "$(stub_log "$F" gpioset)" "no SYS_UP for a board that is not there"
fixture_rm "$F"

# ── The halt marker precedes the wake hook ─────────────────────────────────
describe "the halt marker is written before the wake hook and the notifier run"
daemon_fixture
set_uptime "$F" 4242
stub "$F" wake-guard 'cat "'"$F"'/run/halt-requested" >> "'"$F"'/log/guard-saw" 2>&1 || echo NO-MARKER >> "'"$F"'/log/guard-saw"; exit 0'
stub "$F" notify-state 'cat "'"$F"'/run/halt-requested" >> "'"$F"'/log/notify-saw" 2>&1; exit 0'
run_daemon "$F/bin/notify-state" "$F/bin/wake-guard"
assert_eq "0" "$RUN_RC" "exit 0"
saw=$(stub_log "$F" guard-saw)
assert_contains "$saw" "source=daemon" "wake-guard found a marker from the daemon"
assert_contains "$saw" "state=requested" "in state 'requested' — the wake not yet looked at"
assert_contains "$saw" "reason=2" "carrying the reason register (alarm2)"
assert_contains "$saw" "uptime=$(cut -d. -f1 "$F/proc/uptime")" "stamped with the uptime at the request (the settle loop had ticked the clock on from 4242)"
assert_not_contains "$saw" "NO-MARKER" "and it existed by the time the hook ran"
assert_contains "$(stub_log "$F" notify-saw)" "source=daemon" "the notifier sees it too"
assert_eq "wake-guard notify-state" "$(printf '%s %s' "$(sed -n 1p "$F/log/wake-guard" >/dev/null && echo wake-guard)" "$(sed -n 1p "$F/log/notify-state" >/dev/null && echo notify-state)")" "both hooks ran"
# The marker is written before the reason is read: the reason read is the
# first i2cget after gpiomon, and the marker's own mtime cannot be compared
# at this resolution — so assert the order in the source, as the design says.
if grep -n 'wp_halt_write daemon' "$DAEMON" | cut -d: -f1 | head -n1 | { read -r a; grep -n 'WP_REG_ACTION_REASON") || wp_reason' "$DAEMON" | tail -n1 | cut -d: -f1 | { read -r b; [ "$a" -lt "$b" ]; }; }; then
    ok "the marker is written before the reason register is read"
else
    notok "the marker is written before the reason register is read" "the other units must stand down from the request, not from a later read"
fi
fixture_rm "$F"

describe "a marker that cannot be written is a warning, not a stop"
daemon_fixture
rm -rf "$F/run"; touch "$F/run"      # a file where the directory should be
run_daemon
assert_eq "0" "$RUN_RC" "the daemon still powers off"
assert_contains "$RUN_OUT" "could not write the halt marker" "and says the marker is missing"
assert_contains "$RUN_OUT" "powering off" "poweroff is reached regardless"
fixture_rm "$F"

# ── D9: the wake hook survives a TERM that a stop job would send ───────────
describe "the wake hook runs with TERM ignored"
daemon_fixture
stub "$F" wake-guard 'kill -TERM $$; kill -INT $$; echo survived >> "'"$F"'/log/guard-term"; exit 0'
run_daemon "" "$F/bin/wake-guard"
assert_eq "survived" "$(stub_log "$F" guard-term)" "a TERM and an INT sent to the hook did not kill it"
fixture_rm "$F"

describe "the same stub dies when TERM is not ignored — so the assertion above is load-bearing"
daemon_fixture
stub "$F" wake-guard 'kill -TERM $$; echo survived >> "'"$F"'/log/guard-term"; exit 0'
sh "$F/bin/wake-guard" ensure 2>/dev/null
assert_eq "" "$(stub_log "$F" guard-term)" "run plainly, the stub is killed by its own TERM"
fixture_rm "$F"

# ── The unit ───────────────────────────────────────────────────────────────
describe "wittypi.service bounds its stop at the pre-arm's budget"
assert_eq "TimeoutStopSec=10" "$(grep -E '^TimeoutStopSec=' "$UNIT")" "TimeoutStopSec=10"
if grep -qE '^ExecStart=/usr/libexec/site/wittypi-daemon$' "$UNIT"; then ok "ExecStart is the daemon, unwrapped"; else notok "ExecStart is the daemon, unwrapped"; fi
