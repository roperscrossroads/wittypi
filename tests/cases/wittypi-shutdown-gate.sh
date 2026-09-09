#!/bin/sh
# wittypi-shutdown-gate — the shutdown-command gate.
#
# Functional: the SHIPPED script runs via symlinks named poweroff/halt/
# shutdown (the exact mechanism the image postprocess installs — $0 dispatch
# is the thing under test, so the tests must enter through it), with
# wake-guard, notify, systemctl and the preserved <name>.real originals all
# stubbed as logging executables. Every wake-guard outcome must end in the
# real binary being exec'd — the gate may only ever change how LOUDLY a
# shutdown proceeds, never whether.
#
# Shape: the postprocess must wrap exactly three names and assert reboot
# untouched; the profile.d layer must be interactive-only and never mention
# reboot; the gate must reach the registers only through wake-guard.
#
# The stubs below are GENERATED shell: their $*/${VAR:-} must survive to the
# stub rather than expand at build time — the single quotes are the point.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

GATE="$OPS_UNITS_DIR/wittypi-shutdown-gate"
PROFILE="$OPS_UNITS_DIR/wittypi-shutdown-gate.sh"
# The Yocto recipes that package these scripts live in the meta-wittypi layer
# repo, and the image recipe that wires the /usr/sbin symlinks lives in the
# integrator's own — neither has a path inside this tree to guess at. Both
# variables let an integration build point these cases at the real files;
# absent that, the assertions SKIP by name rather than failing. Same
# convention as WITTYPI_YOCTO_RECIPE in wittypi-board-env.sh.
OPS_BB="${WITTYPI_YOCTO_OPS_RECIPE:-}"
IMAGE_BB="${WITTYPI_YOCTO_IMAGE_RECIPE:-}"
# The name of the integrator's ROOTFS_POSTPROCESS function that rewires
# /usr/sbin. It is THEIRS to name, so it is a seam rather than a literal —
# this file used to hardcode one deployment's choice, which no other consumer
# could satisfy. Defaults to the obvious name; set it if yours differs.
IMAGE_GATE_FUNC="${WITTYPI_YOCTO_IMAGE_GATE_FUNC:-wittypi_gate_shutdown_binaries}"

# A fixture with the whole cast: wake-guard logging its subcommand and
# exiting STUB_WG_STATE (default 0, armed), notify, a systemctl stand-in,
# and the three preserved .real originals logging which of them ran, with
# what arguments. The gate itself is entered through a symlink per name,
# exactly as the image wires it.
gate_fixture() {
    _gf=$(fixture_new)
    mkdir -p "$_gf/sbin"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/wake-guard"\n' "$_gf"
        printf 'exit "${STUB_WG_STATE:-0}"\n'
    } > "$_gf/bin/wake-guard"
    chmod +x "$_gf/bin/wake-guard"
    stub "$_gf" notify 'exit 0'
    stub "$_gf" systemctl 'exit 0'
    for _n in poweroff halt shutdown; do
        {
            printf '#!/bin/sh\n'
            printf 'printf "%%s\\n" "${0##*/} $*" >> "%s/log/real"\n' "$_gf"
            printf 'exit 0\n'
        } > "$_gf/sbin/$_n.real"
        chmod +x "$_gf/sbin/$_n.real"
        ln -s "$GATE" "$_gf/sbin/$_n"
    done
    printf '%s' "$_gf"
}

# run_gate <fixture> <invoked-name> [args...] — through the symlink, so the
# gate sees the name in $0. STUB_WG_STATE/STUB_WG_PATH/WITTYPI_SHUTDOWN_FORCE
# are exported by each case (see lib.sh on why built prefix assignments
# cannot work).
run_gate() {
    _f="$1"; _n="$2"; shift 2
    RUN_OUT=$(
        WITTYPI_SHUTDOWN_GATE_WAKE_GUARD="${STUB_WG_PATH:-$_f/bin/wake-guard}" \
        WITTYPI_SHUTDOWN_GATE_NOTIFY="$_f/bin/notify" \
        WITTYPI_SHUTDOWN_GATE_REAL_DIR="$_f/sbin" \
        WITTYPI_SHUTDOWN_GATE_SYSTEMCTL="$_f/bin/systemctl" \
        "$_f/sbin/$_n" "$@" 2>&1
    )
    RUN_RC=$?
    return 0
}

# run_gate_verb <fixture> [args...] — under its own name, the shape the
# profile.d function uses: the original systemctl argv arrives as arguments.
run_gate_verb() {
    _f="$1"; shift
    RUN_OUT=$(
        WITTYPI_SHUTDOWN_GATE_WAKE_GUARD="${STUB_WG_PATH:-$_f/bin/wake-guard}" \
        WITTYPI_SHUTDOWN_GATE_NOTIFY="$_f/bin/notify" \
        WITTYPI_SHUTDOWN_GATE_REAL_DIR="$_f/sbin" \
        WITTYPI_SHUTDOWN_GATE_SYSTEMCTL="$_f/bin/systemctl" \
        sh "$GATE" "$@" 2>&1
    )
    RUN_RC=$?
    return 0
}

# ── the tri-state: every outcome proceeds; only the volume changes ─────────

describe "poweroff with a wake armed: one ensure, then straight through"
F=$(gate_fixture)
run_gate "$F" poweroff
assert_eq "0" "$RUN_RC" "exits with the real binary's status"
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "exactly one wake-guard call, and it is ensure — atomic, not check-then-ensure"
assert_contains "$(cat "$F/log/real")" 'poweroff.real' "the preserved original ran"
assert_eq "" "$(stub_log "$F" notify)" "nothing to page"
assert_eq "" "$RUN_OUT" "quiet — wake-guard's own verdict line is the only voice"
fixture_rm "$F"

describe "arming FAILED (rc 1): proceeds anyway, loudly, and pages"
F=$(gate_fixture)
export STUB_WG_STATE=1
run_gate "$F" poweroff
assert_contains "$(cat "$F/log/real")" 'poweroff.real' "the shutdown still happens — the gate may never block one"
assert_contains "$RUN_OUT" 'PROCEEDING UNGUARDED' "and says so on the terminal"
assert_contains "$RUN_OUT" 'arming FAILED' "naming the failure, not just the state"
assert_contains "$(stub_log "$F" notify)" '-p high' "paged at high priority"
assert_contains "$(stub_log "$F" notify)" 'NO wake armed' "with the consequence in the message"
unset STUB_WG_STATE
fixture_rm "$F"

describe "controller unreadable (rc 2): proceeds with the distinct wording"
F=$(gate_fixture)
export STUB_WG_STATE=2
run_gate "$F" poweroff
assert_contains "$(cat "$F/log/real")" 'poweroff.real' "still proceeds"
assert_contains "$RUN_OUT" 'could not be read' "unreadable is not the same failure as unarmed"
assert_contains "$(stub_log "$F" notify)" 'unreadable' "and the page says which"
unset STUB_WG_STATE
fixture_rm "$F"

describe "wake-guard missing entirely: still proceeds — a broken gate must not strand the node up"
F=$(gate_fixture)
export STUB_WG_PATH="$F/bin/no-such-wake-guard"
run_gate "$F" poweroff
assert_contains "$(cat "$F/log/real")" 'poweroff.real' "the shutdown happens regardless"
assert_contains "$RUN_OUT" 'PROCEEDING UNGUARDED' "and the absence is loud, not silent"
unset STUB_WG_PATH
fixture_rm "$F"

describe "halt is gated exactly like poweroff"
F=$(gate_fixture)
run_gate "$F" halt
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "same ensure"
assert_contains "$(cat "$F/log/real")" 'halt.real' "through halt's own original"
fixture_rm "$F"

# ── bypasses: the wedge case and the explicit one ──────────────────────────

describe "poweroff -f: the box may be wedged — no gate, argument intact"
F=$(gate_fixture)
run_gate "$F" poweroff -f
assert_eq "" "$(stub_log "$F" wake-guard)" "no I2C work added to a forced shutdown"
assert_contains "$(cat "$F/log/real")" 'poweroff.real -f' "-f passes through — both meanings of force are served"
fixture_rm "$F"

describe "poweroff --force: the long form bypasses too"
F=$(gate_fixture)
run_gate "$F" poweroff --force
assert_eq "" "$(stub_log "$F" wake-guard)" "bypassed"
assert_contains "$(cat "$F/log/real")" 'poweroff.real --force' "and passed through"
fixture_rm "$F"

describe "poweroff -w writes wtmp and cuts nothing: ungated, untouched"
F=$(gate_fixture)
run_gate "$F" poweroff -w
assert_eq "" "$(stub_log "$F" wake-guard)" "nothing will power off, so nothing to arm"
assert_contains "$(cat "$F/log/real")" 'poweroff.real -w' "through untouched"
fixture_rm "$F"

describe "--help never arms anything"
F=$(gate_fixture)
run_gate "$F" poweroff --help
assert_eq "" "$(stub_log "$F" wake-guard)" "a help request is not a shutdown"
assert_contains "$(cat "$F/log/real")" 'poweroff.real --help' "and the real binary prints its own help"
fixture_rm "$F"

describe "WITTYPI_SHUTDOWN_FORCE=1: the explicit bypass, command untouched"
F=$(gate_fixture)
export WITTYPI_SHUTDOWN_FORCE=1
run_gate "$F" poweroff
assert_eq "" "$(stub_log "$F" wake-guard)" "skipped by the env bypass"
assert_contains "$(cat "$F/log/real")" 'poweroff.real' "and still proceeds"
unset WITTYPI_SHUTDOWN_FORCE
fixture_rm "$F"

# ── the SysV parse, case by case ───────────────────────────────────────────

describe "shutdown -r now: reboot-equivalent, deliberately ungated"
F=$(gate_fixture)
run_gate "$F" shutdown -r now
assert_eq "" "$(stub_log "$F" wake-guard)" "reboot never trips the rail-cut detection — nothing to arm"
assert_contains "$(cat "$F/log/real")" 'shutdown.real -r now' "argv reaches systemd intact"
fixture_rm "$F"

describe "shutdown -h now: poweroff-equivalent, gated"
F=$(gate_fixture)
run_gate "$F" shutdown -h now
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "gated"
assert_contains "$(cat "$F/log/real")" 'shutdown.real -h now' "and passed through with the time argument"
fixture_rm "$F"

describe "bare timed shutdown defaults to poweroff: gated"
F=$(gate_fixture)
run_gate "$F" shutdown +10
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "no action flag means poweroff at the given time"
assert_contains "$(cat "$F/log/real")" 'shutdown.real +10' "the schedule survives"
fixture_rm "$F"

describe "shutdown -c cancels — gating a cancellation would be absurd"
F=$(gate_fixture)
run_gate "$F" shutdown -c
assert_eq "" "$(stub_log "$F" wake-guard)" "ungated"
assert_contains "$(cat "$F/log/real")" 'shutdown.real -c' "and the cancel reaches logind"
fixture_rm "$F"

describe "shutdown -k warns without shutting down: ungated"
F=$(gate_fixture)
run_gate "$F" shutdown -k now
assert_eq "" "$(stub_log "$F" wake-guard)" "a wall message is not a power cut"
fixture_rm "$F"

describe "shutdown -f is SysV skip-fsck, NOT force — still gated"
F=$(gate_fixture)
run_gate "$F" shutdown -f now
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "the -f bypass belongs to poweroff/halt only"
fixture_rm "$F"

describe "shutdown -rf: reboot with skip-fsck, ungated"
F=$(gate_fixture)
run_gate "$F" shutdown -rf now
assert_eq "" "$(stub_log "$F" wake-guard)" "combined letters still read as a reboot"
fixture_rm "$F"

describe "shutdown -h -r together: gate wins — an unneeded arm is cheap, a missed one is a site visit"
F=$(gate_fixture)
run_gate "$F" shutdown -h -r now
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "any halt/poweroff letter gates, whatever else is present"
fixture_rm "$F"

# ── verb mode: the profile layer's path ────────────────────────────────────

describe "verb mode: 'systemctl poweroff' arrives as arguments and is gated"
F=$(gate_fixture)
run_gate_verb "$F" poweroff
assert_eq "ensure" "$(stub_log "$F" wake-guard)" "gated"
assert_eq "poweroff" "$(stub_log "$F" systemctl)" "then the original systemctl argv, untouched"
fixture_rm "$F"

describe "verb mode: a non-shutdown verb passes through untouched"
F=$(gate_fixture)
run_gate_verb "$F" status wpa_supplicant
assert_eq "" "$(stub_log "$F" wake-guard)" "not a shutdown"
assert_eq "status wpa_supplicant" "$(stub_log "$F" systemctl)" "verbatim"
fixture_rm "$F"

describe "verb mode: 'status halt' — halt outside the verb position is a unit name, not a shutdown"
F=$(gate_fixture)
run_gate_verb "$F" status halt
assert_eq "" "$(stub_log "$F" wake-guard)" "only the verb position gates"
assert_eq "status halt" "$(stub_log "$F" systemctl)" "query untouched"
fixture_rm "$F"

describe "verb mode: 'poweroff -f' bypasses but keeps -f"
F=$(gate_fixture)
run_gate_verb "$F" poweroff -f
assert_eq "" "$(stub_log "$F" wake-guard)" "force after the verb still bypasses"
assert_eq "poweroff -f" "$(stub_log "$F" systemctl)" "with the flag intact"
fixture_rm "$F"

# ── the defensive fallback, and its one hard refusal ───────────────────────

describe "a missing .real falls back to a verb rather than dying dark"
F=$(gate_fixture)
rm "$F/sbin/poweroff.real"
run_gate "$F" poweroff
assert_contains "$RUN_OUT" 'falling back' "the degradation is named"
assert_eq "poweroff" "$(stub_log "$F" systemctl)" "and the node still powers off"
fixture_rm "$F"

describe "a missing .real on a cancel REFUSES — -c must never translate into a power cut"
F=$(gate_fixture)
rm "$F/sbin/shutdown.real"
run_gate "$F" shutdown -c
assert_eq "1" "$RUN_RC" "refused"
assert_eq "" "$(stub_log "$F" systemctl)" "no verb was invented"
assert_contains "$RUN_OUT" 'cannot honor' "and the refusal says why"
fixture_rm "$F"

describe "a name this gate does not serve is a loud misconfiguration, not a guess"
F=$(gate_fixture)
ln -s "$GATE" "$F/sbin/reboot"
run_gate "$F" reboot
assert_eq "64" "$RUN_RC" "usage error, same convention as wake-guard"
assert_eq "" "$(stub_log "$F" wake-guard)" "nothing armed"
assert_eq "" "$(cat "$F/log/real" 2>/dev/null)" "nothing exec'd — a mis-wired reboot must be discovered, not endorsed"
fixture_rm "$F"

# ── shape: the invariants a refactor must not lose ─────────────────────────

describe "the shipped gate file is executable — the /usr/sbin symlinks exec it directly"
if [ -x "$GATE" ]; then ok "mode +x"; else notok "mode +x" "chmod +x the shipped file or the symlinks cannot run it"; fi

describe "the gate reaches the registers only through wake-guard"
gate_body=$(grep -v '^\s*#' "$GATE")
assert_not_contains "$gate_body" 'i2c' "never touches the bus itself"
assert_not_contains "$gate_body" 'wp_' "never sources the wittypi lib"
assert_not_contains "$gate_body" '/usr/bin/wittypi' "never spawns the CLI"
assert_not_contains "$gate_body" 'flock' "takes no lock — wake-guard's own flock is the serialization"
assert_not_contains "$gate_body" 'trap ' "no traps: nothing to clean up, nothing to slow a SIGTERM"

describe "the gate's defaults are the production paths"
gate_default() { sed -n "s/^$1=\"\${[A-Z_]*:-\([^}]*\)}\"\$/\1/p" "$GATE" | head -1; }
assert_eq "/usr/libexec/site/wake-guard" "$(gate_default GATE_WAKE_GUARD)" "GATE_WAKE_GUARD"
assert_eq "/usr/bin/notify"              "$(gate_default GATE_NOTIFY)"     "GATE_NOTIFY"
assert_eq "/usr/sbin"                    "$(gate_default GATE_REAL_DIR)"   "GATE_REAL_DIR"
assert_eq "/usr/bin/systemctl"           "$(gate_default GATE_SYSTEMCTL)"  "GATE_SYSTEMCTL"

describe "the postprocess wraps exactly three names and polices the fourth"
# The consuming image is not in this repo, and that is correct.
# These six assertions check that the consuming IMAGE rewires /usr/sbin/poweroff
# to the gate. That is the integrator's job, not this repo's — this repo ships
# the gate, not the decision to install it. Reported as skipped rather than
# quietly dropped, because "does anything actually invoke the gate?" is the
# single most important question about it.
if have "${IMAGE_BB:-}" "the consuming image — the integrator owns the wiring"; then
ppc=$(sed -n "/^python ${IMAGE_GATE_FUNC}/,/^}\$/p" "$IMAGE_BB")
if [ -z "$ppc" ]; then
    printf '    SKIPPED: no "python %s" in the image recipe — set\n' "$IMAGE_GATE_FUNC"
    printf '             WITTYPI_YOCTO_IMAGE_GATE_FUNC to your function name\n'
else
assert_contains "$ppc" 'bb.fatal' "the extraction found the function (and it fails loudly)"
names_line=$(printf '%s\n' "$ppc" | grep 'for name in')
assert_contains "$names_line" "('poweroff', 'halt', 'shutdown')" "the wrapped set, exactly"
assert_not_contains "$names_line" 'reboot' "reboot is never in the wrapped list"
assert_contains "$ppc" 'reboot_link' "and its untouched state is ASSERTED, not assumed"
assert_contains "$ppc" ".real" "the originals are preserved, not destroyed"
assert_contains "$ppc" 'profile.d' "the inert-drop-in guard exists"
assert_contains "$(cat "$IMAGE_BB")" "ROOTFS_POSTPROCESS_COMMAND += \"${IMAGE_GATE_FUNC};\"" "and the function is actually registered"
fi
fi

describe "the profile layer: interactive only, absolute paths, reboot never named"
assert_eq '#!/bin/sh' "$(head -n 1 "$PROFILE")" "shebang present so the lint gate selects it"
prof=$(cat "$PROFILE")
assert_contains "$prof" 'systemctl()' "defines the function"
assert_contains "$prof" '*i*' "interactive shells only"
assert_contains "$prof" '/usr/libexec/site/wittypi-shutdown-gate' "redirects to the gate by absolute path"
assert_contains "$prof" '/usr/bin/systemctl' "and passes everything else to the real binary by absolute path"
assert_contains "$prof" 'poweroff|halt' "matching exactly the two gated verbs"
prof_code=$(grep -v '^\s*#' "$PROFILE")
assert_not_contains "$prof_code" 'reboot' "the function must never learn to redirect reboot"

describe "the recipe ships both halves with the right modes"
if have "$OPS_BB" "wittypi-ops_1.0.bb (meta-wittypi layer)"; then
bb=$(cat "$OPS_BB")
# SRC_URI spelling is the integrator's choice, not this repo's business. The
# two install assertions below are what actually matter.
assert_contains "$bb" 'install -m 0755 ${S}/wittypi-shutdown-gate ${D}${libexecdir}/site/wittypi-shutdown-gate' "gate executable in libexec/site"
assert_contains "$bb" 'install -m 0644 ${S}/wittypi-shutdown-gate.sh ${D}${sysconfdir}/profile.d/wittypi-shutdown-gate.sh' "profile.d sourced, not executed: 0644"
assert_contains "$bb" '${sysconfdir}/profile.d/wittypi-shutdown-gate.sh' "and packaged"
fi

describe "the daemon's own path stays clear of the gate by construction"
assert_contains "$(cat "$RPI_UNITS_DIR/wittypi-daemon")" 'exec systemctl poweroff' "the MCU path calls the verb directly — never the wrapped names"
