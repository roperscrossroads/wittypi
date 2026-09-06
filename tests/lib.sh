# Test helpers for the shipped unit scripts. POSIX sh; sourced, not run.
#
# WHAT THESE TESTS ARE, AND WHAT THEY ARE NOT
# -------------------------------------------
# They execute the SHIPPED script files — the same bytes the image installs —
# against a fixture directory, with external commands (fw_setenv, fw_printenv,
# rauc, systemctl, systemd-notify) replaced by stubs on PATH.
#
# Only the ROOT PATHS are injected, via the fixture-path variables the scripts already
# read. cases/defaults.sh asserts that every one of those defaults is the real
# production path, so a typo in a default cannot make the suite quietly test
# something that is not what ships.
#
# What this does NOT cover, and no host-side suite can:
#   * the real kernel's pstore behaviour (records appearing, unlink semantics)
#   * systemd's Type=notify / WatchdogSec interaction
#   * this board's busybox ash — we run under whatever /bin/sh is here
#   * anything in boot.cmd, which is U-Boot script, not shell (see
#     cases/boot-selection.sh for what is and is not claimed there)
#
# So a green run means "the logic is right", never "it works on the board".

TESTS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LAYER_DIR=$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd)

# ── Topology is injected, not derived ──────────────────────────────────────
#
# This is the change that makes a repo split possible, and the hazard it
# carries. In a combined tree these five could all be computed from one
# root, because the repo root and the neutral layer root were the same
# directory. Once related packages live in separate repos, that one root
# stops having a single meaning, and every derivation from it becomes a
# path that happens to exist or happens not to.
#
# So each is now `${VAR:=...}` — the repo sets what it actually has, in
# tests/topology.sh, and anything it does not have stays unset.
#
# An unset directory must SKIP loudly, never pass quietly. A case that greps
# a file under an empty prefix finds nothing, asserts nothing and prints no
# failures — a false-green that's easy to be burned by more than once (see
# the EXIT-trap warning below, and tests/lint.sh's own note about silently
# missing a whole layer). `need_dir` below is the guard: it emits a visible
# SKIP line and a counts line, and exits.
: "${UNITS_DIR:=}"
: "${RK3506_DIR:=}"
: "${RPI_DIR:=}"
: "${RPI_UNITS_DIR:=}"
: "${OPS_UNITS_DIR:=}"
: "${PYDIR:=}"

# Per-repo overrides. Sourced if present so each repo declares only what it owns.
[ -f "$TESTS_DIR/topology.sh" ] && . "$TESTS_DIR/topology.sh"

PASS=0
FAIL=0
CURRENT=""

# The runner parses this line to total up across case files. An EXIT trap emits
# it even if a case dies early, so a case that crashes half way cannot be
# mistaken for one that had nothing to report.
_emit_counts() { printf '__COUNTS__ %d %d\n' "$PASS" "$FAIL"; }
trap _emit_counts EXIT

# Do NOT `trap ... EXIT` in a case file. There is one EXIT trap per shell and
# a second `trap` REPLACES this one, so the counts line is never emitted and
# the runner totals the file as zero — while every assertion in it still
# prints ok and the run still says OK. This has happened for real, in a case
# whose several dozen passing assertions were counted as none.
#
# If a case needs cleanup, prefer not creating the thing that needs cleaning
# (hold it in a variable), or chain explicitly:
#     trap '_emit_counts; rm -f "$tmp"' EXIT

# ---- topology guard ------------------------------------------------------

# need_dir VAR_NAME [VAR_NAME...] — assert every named topology variable is set
# AND points at a real directory. If any is not, print a SKIP and leave: this
# repo does not carry that layer, and a case that ran anyway would assert
# nothing while reporting success.
need_dir() {
    for _n in "$@"; do
        eval "_v=\${$_n:-}"
        if [ -z "$_v" ] || [ ! -d "$_v" ]; then
            printf '    SKIP %s not available in this repo (%s unset or missing)\n' \
                "$(basename "$0" .sh)" "$_n"
            exit 0
        fi
    done
}

# have PATH [WHAT] — does this repo own PATH?
#
# The point is the SKIP line, not the predicate. After a split, a case can
# legitimately reference a file that lives in a different repo: wittypi-lock
# compares against `wake-guard`, which the integration layer owns. Letting the
# assertion simply fail is wrong (nothing is broken); letting it silently
# vanish is worse (the count drops and no one notices). So absence is REPORTED,
# by name, every run.
#
#   if have "$UNITS_DIR/wake-guard" "wake-guard (integration layer)"; then
#       ...assertions...
#   fi
have() {
    [ -n "${1:-}" ] && [ -e "$1" ] && return 0
    printf '    SKIP not in this repo: %s\n' "${2:-${1:-<unset>}}"
    return 1
}

# ---- assertions ----------------------------------------------------------

ok()   { PASS=$(( PASS + 1 )); printf '    ok   %s\n' "$1"; }
notok() {
    FAIL=$(( FAIL + 1 ))
    printf '    FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '         %s\n' "$2"
    return 0
}

# assert_eq <expected> <actual> <description>
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else notok "$3" "expected [$1], got [$2]"; fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *)      notok "$3" "expected to find [$2]" ;;
    esac
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
    case "$1" in
        *"$2"*) notok "$3" "did NOT expect to find [$2]" ;;
        *)      ok "$3" ;;
    esac
}

assert_file_exists() {
    if [ -e "$1" ]; then ok "$2"; else notok "$2" "missing: $1"; fi
}

assert_file_absent() {
    if [ -e "$1" ]; then notok "$2" "should not exist: $1"; else ok "$2"; fi
}

describe() { CURRENT="$1"; printf '  %s\n' "$1"; }

# ---- fixtures ------------------------------------------------------------

# fixture_new -> prints a fresh fixture root
#
# Layout mirrors the parts of the target filesystem the scripts touch:
#   $F/data          -> /data
#   $F/pstore        -> /sys/fs/pstore
#   $F/proc/cmdline  -> /proc/cmdline
#   $F/proc/uptime   -> /proc/uptime
#   $F/bin           -> prepended to PATH (stubs)
#   $F/log           -> where stubs record their invocations
#   $F/log/kmsg      -> /dev/kmsg (so messages meant to survive a reset are
#                       observable; on the board these land in ramoops)
fixture_new() {
    F=$(mktemp -d "${TMPDIR:-/tmp}/site-test.XXXXXX") || exit 1
    mkdir -p "$F/data" "$F/pstore" "$F/proc" "$F/bin" "$F/log"
    printf 'BOOT_IMAGE=/boot/zImage root=/dev/mmcblk0p2 ro panic=10 rauc.slot=A\n' > "$F/proc/cmdline"
    printf '1234.56 2000.00\n' > "$F/proc/uptime"
    # A plausible os-release, so any image hash derived from it is stable per
    # fixture but changes when a test rewrites it (which is the point).
    mkdir -p "$F/etc"
    printf 'ID=wittypi-node\nVERSION_ID=1.0\n' > "$F/etc/os-release"
    printf '%s' "$F"
}

fixture_rm() { [ -n "${1:-}" ] && [ -d "$1" ] && rm -rf -- "$1"; }

# stub <fixture> <name> <body...>  — create a fake command on PATH that logs
# every invocation to $F/log/<name> and then runs <body>.
stub() {
    _f="$1"; _n="$2"; shift 2
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/%s"\n' "$_f" "$_n"
        printf '%s\n' "$*"
    } > "$_f/bin/$_n"
    chmod +x "$_f/bin/$_n"
}

# stub_log <fixture> <name> — print what a stub was called with (empty if never)
stub_log() { cat "$1/log/$2" 2>/dev/null || true; }

# ---- running a unit under test -------------------------------------------

# run_unit <fixture> <script-name> [args...] — run a shipped script against the
# fixture. Captures stdout+stderr into RUN_OUT and the exit status into RUN_RC.
#
# Tunables that are NOT paths (SLOT_FAIL_THRESHOLD, HEALTH_SOAK_SEC,
# PSTORE_KEEP) are not listed here on purpose: `export` them in the case
# and they reach the subshell. Passing them as prefix assignments built by
# expansion does NOT work — POSIX recognises assignment prefixes before
# expansion, so `${X:+VAR=$X} cmd` makes `VAR=x` the command name, not an
# assignment. Silent and confusing; hence this note.
run_unit() {
    _f="$1"; _s="$2"; shift 2
    RUN_OUT=$(
        PATH="$_f/bin:$PATH" \
        SLOT_STATE_DIR="$_f/data/boot-slot-health" \
        PSTORE_DIR="$_f/pstore" \
        PSTORE_DEST="$_f/data/pstore" \
        PROC_CMDLINE="$_f/proc/cmdline" \
        DATA_DIR="$_f/data" \
        PROC_UPTIME="$_f/proc/uptime" \
        ETC_OSRELEASE="$_f/etc/os-release" \
        DEV_KMSG="$_f/log/kmsg" \
        GUARD_DEV="$_f/sys-block-mmcblk0" \
        UPDATE_CANARY="$_f/update-canary.raucb" \
        sh "$UNITS_DIR/$_s" "$@" 2>&1
    )
    RUN_RC=$?
    return 0
}

# run_rpi_unit <fixture> <script-name> [args...] — run_unit's counterpart for
# the scripts at the repo root (RPI_UNITS_DIR).
#
# Kept as a second function rather than parameterising run_unit: every existing
# case calls run_unit with two arguments, and adding a leading directory
# argument would silently reinterpret the script name as the directory in all of
# them. The duplication is four lines; the alternative is a rewrite of thirteen
# case files to fix a problem none of them have.
#
# WITTYPI_LIB is passed because the shipped scripts source it by absolute path
# (/usr/libexec/site/...), which does not exist on a build host.
run_rpi_unit() {
    _f="$1"; _s="$2"; shift 2
    RUN_OUT=$(
        PATH="$_f/bin:$PATH" \
        DATA_DIR="$_f/data" \
        PROC_UPTIME="$_f/proc/uptime" \
        DEV_KMSG="$_f/log/kmsg" \
        WITTYPI_LIB="$RPI_UNITS_DIR/wittypi-lib.sh" \
        sh "$RPI_UNITS_DIR/$_s" "$@" 2>&1
    )
    RUN_RC=$?
    return 0
}

# ---- fixture conveniences ------------------------------------------------

set_slot()   { printf 'BOOT_IMAGE=/boot/zImage ro rauc.slot=%s\n' "$2" > "$1/proc/cmdline"; }
set_uptime() { printf '%s.00 2000.00\n' "$2" > "$1/proc/uptime"; }

# A warm reset that left a panic record.
pstore_panic() { printf 'kernel panic - not syncing\n' > "$1/pstore/dmesg-ramoops-0"; }

# A warm reset with only a console record containing <text>.
pstore_console() { printf '%s\n' "$2" > "$1/pstore/console-ramoops-0"; }

# A cold boot: DRAM lost, so pstore is empty. This is what load-shedding looks
# like, and the reason it cannot forge a failure.
pstore_cold() { rm -f "$1"/pstore/* 2>/dev/null || true; }

# kmsg_log <fixture> — what the unit wrote to /dev/kmsg. On the board these are
# the messages that survive a warm reset via ramoops, so they are the ONLY
# diagnostics available after a crash. Worth asserting on for that reason.
kmsg_log() { cat "$1/log/kmsg" 2>/dev/null || true; }
