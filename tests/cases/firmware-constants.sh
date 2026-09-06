#!/bin/sh
# The constants the firmware patches and userspace BOTH hold.
#
# WHY THIS FILE EXISTS
# --------------------
# firmware/wittypi/0001 introduced values that now exist in two places at
# once — once in the AVR source under firmware/wittypi/, and once in the
# shell that talks to it:
#
#   the button sentinel     0x5A  vs  the 90 wp_reg_decode compares against
#   the default-on ceiling  32    vs  WP_MAX_DEFAULT_ON_DELAY
#   the power-cut seed      200   vs  WP_FALLBACK_POWER_CUT_DELAY (x10)
#
# That's the same kind of duplication this layer works hard to avoid
# elsewhere, reintroduced by the patch that fixed something else. All three
# agree today and nothing whatsoever holds them together, which is the state
# every one of this layer's timing bugs started in.
#
# Why the patch files and not the vendor tree: the obvious check — read the
# firmware source — cannot run here: a vendor checkout is not in this repo,
# is not on the board, and on any machine that has it the patches may or may
# not be applied. The patches themselves ARE in this repo and are what we
# intend to flash, so they're the authority available offline. This asserts
# that what we will flash and what we ship to talk to it agree.
#
# What this does NOT check: that the patches still apply. That needs the
# vendor tree; `git apply --check` against it is a bench step, recorded in
# firmware/wittypi/README.md, not something an offline suite can do.
. "$(dirname "$0")/../lib.sh"

# Take the topology-provided variable rather than re-deriving a path here —
# a hardcoded path that happens to match this repo's own layout is exactly
# the kind of thing that silently breaks the moment a directory gets
# renamed or the package is used from a different tree.
PATCH_DIR="${WITTYPI_FIRMWARE_DIR:-$LAYER_DIR/firmware/wittypi}"
LIB="$RPI_UNITS_DIR/wittypi-lib.sh"
POLICY="$RPI_UNITS_DIR/wittypi"

# Added lines only. A diff carries the OLD value too, on a '-' line, and a
# grep that ignores the prefix would happily read the thing the patch
# removes — e.g. reporting the power-cut seed as the vendor's original 70,
# the exact value the patch exists to replace.
patch_define() {
    sed -n "s/^+#define $2  *\\([0-9A-Fa-fx]*\\).*/\\1/p" "$PATCH_DIR/$1" | head -n 1
}
patch_seed() {
    sed -n "s/^+  i2cReg\\[$2\\] = \\([0-9]*\\);.*/\\1/p" "$PATCH_DIR/$1" | head -n 1
}
shell_num() { sed -n "s/^$2=\\(-\\{0,1\\}[0-9][0-9]*\\).*/\\1/p" "$1" | head -n 1; }

as_dec() { [ -n "$1" ] && echo $(( $1 )) || echo ""; }

describe "the patch files are where the flashing procedure expects them"
assert_file_exists "$PATCH_DIR/0001-fail-on-not-fail-dark.patch" "0001 is in the apply path"

describe "the button sentinel matches the value userspace decodes against"
# wp_reg_decode prints "WAITS FOR THE BUTTON" for exactly one value of register
# 17 when the site marker is present. If the firmware's sentinel moves and this
# does not, the tool reports a node as bootable when it is not.
FW_SENTINEL=$(as_dec "$(patch_define 0001-fail-on-not-fail-dark.patch DEFAULT_ON_BUTTON_VALUE)")
# Reads the case ARM in wp_reg_decode's register-17 switch, matching its
# current shape (it states both firmwares' readings) rather than an older
# single-comparison form — if the decode's shape changes again, this
# extractor should fail loudly rather than silently match nothing and pass
# an empty string.
SH_SENTINEL=$(sed -n 's/^ *\([0-9][0-9]*\)) echo "site fw: WAITS.*/\1/p' "$LIB" | head -n 1)
assert_eq "90" "$FW_SENTINEL" "0001 defines the sentinel as 0x5A (90 decimal)"
assert_eq "$FW_SENTINEL" "$SH_SENTINEL" \
    "wp_reg_decode compares register 17 against the SAME value the firmware waits on"

describe "the site marker is gone from the apply path"
# No register in the applied firmware says "this is our firmware" —
# identification is by reading flash back and comparing against the built
# hex, which verifies the whole image rather than one byte.
if grep -qE '^\+#define I2C_SITE_MARK' "$PATCH_DIR/0001-fail-on-not-fail-dark.patch"; then
    notok "0001 does not carry the site marker" "found I2C_SITE_MARK defined in 0001"
else
    ok "0001 does not carry the site marker"
fi

describe "the delay mask bounds the value below what userspace refuses"
# Both sides bound this and they must agree. The firmware masks at the point
# of use; userspace refuses to write anything larger. If userspace allowed more
# than the mask admits, a value would be written, read back as itself, and
# behave as something else — configure and check would agree forever while the
# hardware did a third thing.
FW_MASK=$(sed -n 's/^+.*DEFAULT_ON_DELAY\] & \(0x[0-9A-Fa-f]*\)).*/\1/p' \
          "$PATCH_DIR/0001-fail-on-not-fail-dark.patch" | head -n 1)
SH_MAX=$(shell_num "$LIB" WP_MAX_DEFAULT_ON_DELAY)
assert_eq "0x1F" "$FW_MASK" "0001 masks the delay with 0x1F"
if [ -n "$FW_MASK" ] && [ "$(( FW_MASK ))" -le "${SH_MAX:-0}" ]; then
    ok "the mask admits at most $(( FW_MASK )), inside WP_MAX_DEFAULT_ON_DELAY ($SH_MAX)"
else
    notok "the mask is inside what userspace refuses" \
"mask admits $(( FW_MASK )) but userspace refuses above ${SH_MAX:-unset}.
A value userspace accepts must be one the firmware will honour unchanged."
fi
# 31 * 1000 = 31000, the last product that fits a signed 16-bit int.
if [ "$(( FW_MASK * 1000 ))" -le 32767 ]; then
    ok "$(( FW_MASK )) * 1000 = $(( FW_MASK * 1000 )) fits int16 — no overflow reachable"
else
    notok "the masked value cannot overflow int16" "$(( FW_MASK * 1000 )) exceeds 32767"
fi

describe "the firmware's power-cut seed matches the policy's fallback"
# Register 21 is deci-seconds, so the firmware seed is ten times the shell one.
# They only both apply on a board whose EEPROM was erased — but that is exactly
# the flashing procedure 0001 recommends, so a disagreement would land on a
# freshly flashed node and nowhere else.
FW_PCD=$(patch_seed 0001-fail-on-not-fail-dark.patch I2C_CONF_POWER_CUT_DELAY)
SH_PCD=$(shell_num "$POLICY" WP_FALLBACK_POWER_CUT_DELAY)
assert_eq "250" "$FW_PCD" "0001 seeds register 21 with 250 (25.0 s), not the vendor 70"
if [ -n "$SH_PCD" ] && [ "$FW_PCD" = "$(( SH_PCD * 10 ))" ]; then
    ok "the seed is exactly 10x WP_FALLBACK_POWER_CUT_DELAY (${SH_PCD}s)"
else
    notok "the seed is exactly 10x WP_FALLBACK_POWER_CUT_DELAY" \
"firmware seeds $FW_PCD (deci-seconds), the policy falls back to ${SH_PCD:-unset}s.
A freshly flashed board would run one budget until wittypi-configure ran, and
the other afterwards — and both would look deliberate."
fi

describe "no default-on seed is needed, because zero now means ON"
# An earlier version of this patch seeded register 17 = 1, which cost 4
# bytes this firmware doesn't have to spare. i2cReg is a plain global, so a
# wiped EEPROM leaves register 17 at 0 — and under `!= 0x5A`, zero powers on.
# The polarity flip subsumes the seed. On a firmware with two spare bytes,
# noticing that was the difference between fitting and not.
if grep -qE '^\+.*i2cReg\[I2C_CONF_DEFAULT_ON\] = ' "$PATCH_DIR/0001-fail-on-not-fail-dark.patch"; then
    notok "0001 does not seed register 17" \
        "the seed is redundant under != 0x5A and costs 4 bytes the flash does not have"
else
    ok "0001 does not seed register 17 — the flip makes zero mean ON"
fi
SENTINEL_DEC=$(as_dec "$(patch_define 0001-fail-on-not-fail-dark.patch DEFAULT_ON_BUTTON_VALUE)")
if [ "$SENTINEL_DEC" != "0" ]; then
    ok "and the sentinel is not 0, so a wiped board is not the one that waits"
else
    notok "the sentinel is not 0" \
        "a wiped EEPROM zero-initialises register 17; a sentinel of 0 would leave every freshly flashed board dark"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  The patches must not silently contradict timing-terms
# ═══════════════════════════════════════════════════════════════════════════
#
# This is the gap the other checks leave open, and it is not hypothetical.
#
# timing-terms pins the controller's behavioural constants, and
# `timing-windows` cross-checks them against the firmware SOURCE. But the source
# it reads is the VENDOR tree — so if a patch in this directory changes one of
# those constants, the cross-check compares terms against unpatched code, finds
# agreement, and reports it. Meanwhile the board is flashed with something else.
#
# The concrete case: WITTYPI.md recommends considering raising
# skipTempShutdownCount above T_MARKGOOD to close the 192-second thermal
# window. That is a one-line patch, and without this check it would leave
# timing-terms saying 120, `timing-windows` saying "agrees with the firmware
# source", and the hazard reported against a number the hardware no longer has.
#
# So: whenever a patch ADDS a line that redefines a constant timing-terms pins,
# the two must agree. A patch that changes one and updates timing-terms passes.
# A patch that changes one and forgets does not.
# timing-terms ships from this repo, beside the firmware patches it is checked
# against, so the default is the in-repo copy and this case runs for real.
# WITTYPI_TIMING_TERMS still overrides it, which is what an integration build
# uses to check the terms file it actually installed rather than the source.
TERMS="${WITTYPI_TIMING_TERMS:-$RPI_DIR/timing-terms}"

term_val() { sed -n "s/^$1=\([0-9][0-9]*\)$/\1/p" "$TERMS" | head -n 1; }

describe "no patch changes a constant timing-terms pins without saying so"
have "$TERMS" "timing-terms" || exit 0

# Heredoc, not a pipe — this has cost a real bug before.
# A piped version would look like `printf '%s\n' "$PINNED" | while IFS='|' read ...`.
# A piped `while` runs in a SUBSHELL, so every ok/notok inside it incremented
# PASS and FAIL in a child that then exited. Mutation-testing it — adding a
# patch line that raises the thermal inhibit to 330 without updating
# timing-terms — printed the FAIL, with the right message, and the case still
# reported "13 passed, 0 failed ... OK".
#
# That is the exact failure this whole file exists to prevent, in the file
# itself: a check that looks like it works, and cannot fail. Redirecting from a
# heredoc keeps the loop in the current shell, where the counters live.
while IFS='|' read -r _key _name _bre; do
    [ -n "$_key" ] || continue
    _want=$(term_val "$_key")
    _found=$(cat "$PATCH_DIR"/*.patch 2>/dev/null | sed -n "s/$_bre.*/\1/p" | head -n 1)
    if [ -z "$_found" ]; then
        ok "no patch redefines $_name (timing-terms keeps $_key=$_want)"
    elif [ "$_found" = "$_want" ]; then
        ok "a patch sets $_name to $_found and timing-terms agrees"
    else
        notok "a patch that changes $_name updates timing-terms too" \
"a patch sets $_name to $_found; timing-terms still says $_key=$_want.

\`timing-windows\` cross-checks timing-terms against the VENDOR source, which is
unpatched — so it would report agreement while the flashed controller behaves
differently. Update $_key in timing-terms to $_found, or drop the patch hunk."
    fi
done <<'PINNED_EOF'
FW_THERMAL_INHIBIT|the thermal inhibit|^+.*skipTempShutdownCount < \([0-9][0-9]*\)
FW_ALARM_WINDOW|the alarm match window|^+.*overdue_alarm1 >= 0 && overdue_alarm1 < \([0-9][0-9]*\)
FW_ALARM1_RETRY|the alarm1 retry|^+.*alarm1Delayed == \([0-9][0-9]*\)
FW_PULSE_INTERVAL|the sleep pulse interval|^+ *i2cReg\[I2C_CONF_PULSE_INTERVAL\] = \([0-9][0-9]*\);
FW_REV|the vendor revision|^+ *i2cReg\[I2C_FW_REVISION\] = 0x0*\([0-9][0-9]*\);
PINNED_EOF
