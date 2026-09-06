#!/bin/sh
# The board-calibration registry: identity resolution, the apply-if-unset
# loader, and the precedence contract (/data — i.e. the environment — always
# beats the registry). The integration half runs the real `wittypi configure`
# against the stub bus and proves a registry value actually reaches register
# 37, and that a site value still wins over it — the two behaviours the whole
# scheme stands on.
#
# The i2c stub below is GENERATED shell ($4/$5 must survive to the stub, not
# expand at build time) — the single quotes are the point.
# shellcheck disable=SC2016
. "$(dirname "$0")/../lib.sh"

LIB="$RPI_UNITS_DIR/wittypi-lib.sh"

# Local copies of wittypi.sh's file-local helpers (same precedent as
# wake-guard.sh): the write-through i2c stub, the rev-7 board marker, and
# the read-back-as-a-NUMBER helper — see wittypi.sh for why reg_dec cannot
# be a cat.
stub_i2c() {
    mkdir -p "$1/regs"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/log/i2cset"\n' "$1"
        printf '[ "$4" = "${WP_DROP_REG:-none}" ] && exit 0\n'
        printf 'printf "%%s\\n" "$5" > "%s/regs/$4"\n' "$1"
    } > "$1/bin/i2cset"
    {
        printf '#!/bin/sh\n'
        printf '[ "$4" = "0" ] && { echo 0x26; exit 0; }\n'
        printf 'if [ -f "%s/regs/$4" ]; then cat "%s/regs/$4"; else echo 0x00; fi\n' "$1" "$1"
    } > "$1/bin/i2cget"
    chmod +x "$1/bin/i2cset" "$1/bin/i2cget"
}
stub_board_rev7() { printf '0x07\n' > "$1/regs/12"; }
reg_dec() {
    if [ -f "$1/regs/$2" ]; then echo $(( $(cat "$1/regs/$2") )); else echo 0; fi
}

# Run a fragment with the lib sourced, fixture bin on PATH. stdout only —
# each fragment prints exactly what its assertion compares.
lib_call() { _f=$1; shift; ( PATH="$_f/bin:$PATH" sh -c ". '$LIB'; $*" 2>/dev/null ); }

describe "wp_board_id: the Pi serial, leading zeros stripped"
F=$(fixture_new)
printf 'processor\t: 0\nSerial\t\t: 00000000a00526a1\n' > "$F/cpuinfo"
export WP_BOARD_CPUINFO="$F/cpuinfo"
assert_eq "a00526a1" "$(lib_call "$F" wp_board_id)" "serial resolved and normalised"
unset WP_BOARD_CPUINFO
fixture_rm "$F"

describe "wp_board_id: no serial falls back to the MAC, colons stripped"
F=$(fixture_new)
printf 'processor\t: 0\n' > "$F/cpuinfo"
printf 'aa:bb:cc:dd:ee:ff\n' > "$F/mac"
export WP_BOARD_CPUINFO="$F/cpuinfo" WP_BOARD_MAC="$F/mac"
assert_eq "aabbccddeeff" "$(lib_call "$F" wp_board_id)" "MAC fallback resolved"
unset WP_BOARD_CPUINFO WP_BOARD_MAC
fixture_rm "$F"

describe "wp_board_id: neither source is an error, not a guess"
F=$(fixture_new)
export WP_BOARD_CPUINFO="$F/absent" WP_BOARD_MAC="$F/also-absent"
lib_call "$F" wp_board_id >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc" "no identity refuses rather than inventing one"
unset WP_BOARD_CPUINFO WP_BOARD_MAC
fixture_rm "$F"

describe "wp_board_id: WITTYPI_BOARD_ID overrides both sources"
F=$(fixture_new)
printf 'Serial\t\t: 00000000deadbeef\n' > "$F/cpuinfo"
export WP_BOARD_CPUINFO="$F/cpuinfo" WITTYPI_BOARD_ID=bench-override
assert_eq "bench-override" "$(lib_call "$F" wp_board_id)" "the escape hatch wins"
unset WP_BOARD_CPUINFO WITTYPI_BOARD_ID
fixture_rm "$F"

describe "the loader fills what the environment leaves unset — and ONLY that"
F=$(fixture_new)
mkdir -p "$F/boards"
printf 'WITTYPI_RTC_OFFSET=77\nWITTYPI_ADJ_VIN=21\n' > "$F/boards/testboard.env"
export WITTYPI_BOARD_ID=testboard WITTYPI_BOARD_DIR="$F/boards"
assert_eq "77" "$(lib_call "$F" 'wp_load_board_env >/dev/null 2>&1; printf %s "${WITTYPI_RTC_OFFSET:-unset}"')" \
    "an unset variable takes the registry value"
export WITTYPI_RTC_OFFSET=119
assert_eq "119" "$(lib_call "$F" 'wp_load_board_env >/dev/null 2>&1; printf %s "${WITTYPI_RTC_OFFSET:-unset}"')" \
    "a set variable is NOT overridden — /data always wins"
export WITTYPI_ADJ_VIN=
assert_eq "SET-EMPTY" "$(lib_call "$F" 'wp_load_board_env >/dev/null 2>&1; printf %s "${WITTYPI_ADJ_VIN-unset}${WITTYPI_ADJ_VIN:+nonempty}"; [ -z "${WITTYPI_ADJ_VIN:-}" ] && printf SET-EMPTY')" \
    "set-but-empty counts as set — a deliberate blank is intent"
unset WITTYPI_RTC_OFFSET WITTYPI_ADJ_VIN WITTYPI_BOARD_ID WITTYPI_BOARD_DIR
fixture_rm "$F"

describe "no file for this board is the ordinary case, not an error path"
F=$(fixture_new)
mkdir -p "$F/boards"
export WITTYPI_BOARD_ID=unregistered WITTYPI_BOARD_DIR="$F/boards"
lib_call "$F" 'wp_load_board_env' >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc" "returns 1 quietly"
unset WITTYPI_BOARD_ID WITTYPI_BOARD_DIR
fixture_rm "$F"

describe "a registry file cannot smuggle anything but WITTYPI_ variables"
F=$(fixture_new)
mkdir -p "$F/boards"
{
    printf '# a comment, fine\n'
    printf 'PATH=/evil\n'
    printf 'WITTYPI_BAD-NAME=1\n'
    printf 'rm -rf /\n'
    # The load-bearing case: a command substitution IN THE NAME. The var
    # name reaches an eval, so without the strict name validation this line
    # EXECUTES its payload. The PATH= and BAD-NAME lines above are caught by
    # cheaper filters and would survive the validation being deleted — this
    # one is the reason the validation exists, and a mutation test that
    # deletes it must fail HERE, not on the cheaper lines.
    printf 'WITTYPI_$(touch %s/pwned)=1\n' "$F"
    printf 'WITTYPI_RTC_OFFSET=42\n'
} > "$F/boards/hostile.env"
export WITTYPI_BOARD_ID=hostile WITTYPI_BOARD_DIR="$F/boards"
out=$(lib_call "$F" 'wp_orig_path=$PATH; wp_load_board_env >/dev/null 2>&1; [ "$PATH" = "$wp_orig_path" ] && printf PATH-INTACT; printf ",%s" "${WITTYPI_RTC_OFFSET:-unset}"')
assert_eq "PATH-INTACT,42" "$out" "hostile lines skipped, the honest one applied, PATH untouched"
assert_file_absent "$F/pwned" "and the name-injection payload NEVER executed"
unset WITTYPI_BOARD_ID WITTYPI_BOARD_DIR
fixture_rm "$F"

describe "end to end: a registry trim reaches register 37 through the real configure"
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
mkdir -p "$F/boards"
printf 'WITTYPI_RTC_OFFSET=77\n' > "$F/boards/testboard.env"
export WITTYPI_TOPOLOGY=usb5v WITTYPI_BOARD_ID=testboard WITTYPI_BOARD_DIR="$F/boards"
run_rpi_unit "$F" wittypi configure
assert_eq "0" "$RUN_RC" "configure succeeds with a registry file present"
assert_eq "77" "$(reg_dec "$F" 37)" "the registry's calibration reached the hardware"
assert_contains "$RUN_OUT" 'board testboard' "and the applied file is named in the output"
fixture_rm "$F"

describe "end to end: the site's value still beats the registry on the same register"
F=$(fixture_new); stub_i2c "$F"; stub_board_rev7 "$F"
mkdir -p "$F/boards"
printf 'WITTYPI_RTC_OFFSET=77\n' > "$F/boards/testboard.env"
export WITTYPI_RTC_OFFSET=119
run_rpi_unit "$F" wittypi configure
assert_eq "119" "$(reg_dec "$F" 37)" "the environment (i.e. /data/wittypi.env) won"
unset WITTYPI_RTC_OFFSET WITTYPI_TOPOLOGY WITTYPI_BOARD_ID WITTYPI_BOARD_DIR
fixture_rm "$F"

describe "the registry ships a worked example, and it has the right shape"
# This deliberately does not assert a real board's measured values. A real
# registry file carries one specific Pi's serial, its wlan0 MAC, and that
# HAT's measured crystal and ADC trims — a machine fingerprint, and values
# that are actively WRONG for anyone else's board. It stays with whichever
# deployment owns it, not in this repo.
#
# What's asserted instead is the property that actually matters to this
# layer: the registry MECHANISM works, and a registered board carries the
# four keys in the shape wittypi reads. example.env is pinned by value
# precisely because it's fake — a placeholder that drifts is a placeholder
# nobody trusts.
BOARDS_DIR="$RPI_UNITS_DIR/boards"
assert_file_exists "$BOARDS_DIR/example.env" "the worked example ships"
assert_file_exists "$BOARDS_DIR/README" "and the registration procedure with it"
first_board=$(cat "$BOARDS_DIR/example.env")
assert_contains "$first_board" 'WITTYPI_RTC_OFFSET=0' "carrying a placeholder crystal trim"

# The ADC trims are asserted as present and numeric, not as particular
# values — pinning one to a specific number (as an earlier version of this
# test did, asserting a value that was really just the "not yet measured"
# placeholder rather than anything read off real hardware) means the suite
# fails the moment a board gets calibrated for real, for the board being
# MORE correct.
#
# RTC_OFFSET stays pinned by value, and the distinction is real: it is one
# crystal's measured property, a firmware flash destroys it for good, and it
# should never change quietly. The ADJ trims are expected to be re-measured
# whenever someone puts a meter on the board — pinning them turns ordinary
# recalibration into a test failure, which trains people to edit tests rather
# than read them.
for k in WITTYPI_ADJ_VIN WITTYPI_ADJ_VOUT WITTYPI_ADJ_IOUT; do
    v=$(printf '%s\n' "$first_board" | sed -n "s/^$k=\\(-\\{0,1\\}[0-9][0-9]*\\)\$/\\1/p" | sed -n 1p)
    if [ -n "$v" ]; then
        ok "$k is present and numeric ($v)"
    else
        notok "$k is present and numeric" "absent, empty, or not an integer"
    fi
done
# The Yocto recipe that packages this registry into an image lives entirely
# in the meta-wittypi layer repo, not this one — there's no path within this
# repo's own tree to guess at. WITTYPI_YOCTO_RECIPE lets an integration
# build point this case at it; absent that, skip cleanly.
BB_RECIPE="${WITTYPI_YOCTO_RECIPE:-}"
if have "$BB_RECIPE" "wittypi_1.0.bb (meta-wittypi layer)"; then
assert_contains "$(cat "$BB_RECIPE")" 'wittypi-boards' \
    "wittypi_1.0.bb installs the registry"
fi
