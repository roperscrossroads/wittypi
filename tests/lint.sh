#!/bin/sh
# Static lint for the shipped shell units.
#
# WHY -s sh MATTERS MORE THAN THE REST
# ------------------------------------
# The image ships busybox, not bash. A bashism therefore fails on the board and
# nowhere else — not in review, and not under `sh -n`, because most of them are
# RUNTIME errors rather than parse errors. One shipped in this layer:
#
#     next=$(( 10#${last:-0} + 1 ))
#
# `10#` is bash's base prefix. dash and busybox ash both abort with
# "arithmetic expression: expecting EOF", so pstore-archive would have died
# every time it actually had a crash record to file. `sh -n` passed it happily.
#
# The SC3xxx family is exactly "this is not POSIX sh", which is the check that
# would have caught it before the tests did. (Note: a comment starting with the
# literal word after '#' that names this tool is parsed as a DIRECTIVE, so prose
# about it has to be worded around -- which cost a lint failure to discover.)
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
LAYER=$(CDPATH='' cd -- "$HERE/.." && pwd)
# Every recipe's files/ dir, not one hard-coded path. device-identity lives in a
# different recipe and had NEVER been linted because this named only one — and it
# runs in early boot, before networkd, deriving the MAC. A bashism there is fatal
# and board-only, which is precisely what this gate exists to catch.
UNITS="$LAYER/recipes-core"

# ── THE SAME BUG, ONE LEVEL UP ─────────────────────────────────────────────
# The comment above is about missing a RECIPE. This is about missing a LAYER.
#
# In the layer this came from, a reorganisation moved machine-specific recipes
# into nested layers and this gate did not follow. It stayed pointed at the old
# root and went on reporting success — and only escaped notice because the
# nested layers shipped no shell script yet, so the count never dropped and
# nothing looked wrong.
#
# wittypi is the first, and it is the worst possible candidate to leave
# unchecked: it runs as root, owns the node's power, and a bashism in it means
# the rail is never cut. Select on the path shape (*/files/*) rather than on a
# root, so a THIRD layer cannot repeat this.
# ── AND ONE LEVEL UP AGAIN: the repo split ────────────────────────────────
# The comment above is about missing a LAYER inside one repo. After the split
# there are four repos, and a hard-coded list here would miss whole REPOS the
# same way it missed whole layers. So the roots are injected: each repo declares
# what it owns in tests/topology.sh, and the default is "everything under this
# repo that looks like a layer".
LINT_ROOTS="${LINT_ROOTS:-}"
[ -f "$HERE/topology.sh" ] && . "$HERE/topology.sh"
if [ -z "$LINT_ROOTS" ]; then
    # Anything with a conf/layer.conf is a layer root; plus the repo itself.
    LINT_ROOTS="$LAYER"
    for _d in "$LAYER"/meta-*; do
        [ -f "$_d/conf/layer.conf" ] && LINT_ROOTS="$LINT_ROOTS $_d"
    done
fi
UNITS_NESTED="$LINT_ROOTS"

if ! command -v shellcheck >/dev/null 2>&1; then
    # Exiting 0 here is safe on a workstation and wrong in CI: a runner
    # without shellcheck would report this gate green having run nothing.
    # LINT_STRICT=1 turns the skip into a failure. CI must set it.
    if [ "${LINT_STRICT:-0}" = "1" ]; then
        printf 'shellcheck not installed and LINT_STRICT=1 — FAILING.\n' >&2
        exit 1
    fi
    printf 'shellcheck not installed — SKIPPING the bashism gate.\n'
    printf 'This is the check that catches "works in bash, dies on busybox".\n'
    printf 'Install it:  apt install shellcheck   (or: pip install shellcheck-py)\n'
    exit 0
fi

rc=0
units_linted=0

# Selected by SHEBANG, not by filename prefix.
#
# This loop used to glob "$UNITS"/lyra-* — and when the units were renamed to
# drop that prefix, the glob matched NOTHING. The gate went on printing the test
# files and exiting 0 while checking none of the shipped scripts, which are the
# only ones where a bashism actually reaches the board. Caught by accident during
# the rename; the counter below is so it cannot happen quietly again.
#
# That is the third time a gate here has reported success while checking nothing:
# a missing shellcheck (skipped silently), lint.sh shipped mode 644 so it never ran,
# and this. Three different causes, one shape.
# Hence: select on content, and assert the count.
# bench/ is included because those scripts run on the BUILD HOST, whose /bin/sh
# is dash — the same class of "works in bash, dies elsewhere" failure the units
# have, in a place where the failure lands mid-loop rather than at parse time.
# They are counted separately: units_linted below asserts the SHIPPED scripts
# were reached, and bench scripts must not be able to satisfy that count.
#
# ── THE DIALECT COMES FROM THE SHEBANG, NOT FROM A BLANKET FLAG ────────────
#
# Everything used to be checked with `-s sh`, which was right while the only
# inputs were the shipped units — they are all `#!/bin/sh` and MUST be POSIX,
# and cases/defaults.sh asserts that shebang for every one of them.
#
# It is wrong for bench/. Three of those scripts declare `#!/usr/bin/env bash`
# ON PURPOSE: they run on a workstation, drive ssh and serial, and use pipefail.
# Forcing POSIX mode on them produced 18 SC3xxx/SC2015 complaints that were not
# defects at all — the tool was being asked the wrong question. And a gate that
# cries wolf is a gate people start bypassing, which for this repo means
# SKIP_CHECK=1 in front of a flash.
#
# So the flag is applied where it is a real constraint (the shipped units) and
# left to the shebang everywhere else. A bench script that says `#!/bin/sh` —
# vm-loop.sh does, because it runs under the build host's dash — still gets full
# POSIX checking, from its own declaration rather than from this loop's opinion.
# The second files/ glob reaches MACHINE OVERRIDE subdirectories
# (files/qemuarm/...). Those are shipped scripts too — just to a different
# machine — and they were invisible to this loop when it only looked one level
# deep, which is the same shape as the glob that once matched nothing at all.
# They count toward units_linted deliberately: a shipped script is a shipped
# script, and the counter's job is to prove the loop reached the recipes.
# And once more, at repo scale: naming layer directories literally in this
# list would be precisely the hardcoded-list failure the two comments above
# are about, one level higher again. Once packages are split across repos,
# a hardcoded directory name is wrong everywhere except the repo it was
# written in, and a loop built on it would go on printing test files and
# exiting 0.
#
# So the roots are iterated, not spelled. Selection is still by path SHAPE
# and by shebang, exactly as argued above — the roots only say WHERE to
# look, never WHAT counts.
#
# Shipped candidates and test candidates are two SEPARATE lists rather than
# one combined glob discriminated by a path-shape guess after the fact — a
# repo whose shipped scripts sit flat at its own root (no recipes-*/files/
# nesting at all) has no shape left to guess from, and a guess that happens
# to also match a test file would silently miscount. Membership in the
# shipped list is what makes something a "unit"; nothing about its path has
# to look a particular way.
_candidates=""
for _root in $UNITS_NESTED; do
    _candidates="$_candidates $_root/recipes-*/*/files/* $_root/recipes-*/*/files/*/* \
        $_root/firmware/*/* $_root/*"
done
_candidates="$_candidates $UNITS/*/files/* $UNITS/*/files/*/*"

_test_candidates="$HERE/run.sh $HERE/lint.sh $HERE/cases/*.sh"
[ -d "$LAYER/bench" ] && _test_candidates="$_test_candidates $LAYER/bench/*.sh"

# shellcheck disable=SC2086  # word-splitting the glob list is the point
for f in $_candidates; do
    [ -f "$f" ] || continue
    case "$f" in *.service|*.conf|*.rules|*.mount) continue ;; esac
    head -n 1 "$f" | grep -q '^#!.*sh' || continue
    printf '  %s\n' "${f#"$LAYER"/}"
    units_linted=$(( units_linted + 1 ))
    # -s sh regardless of shebang: these reach the board's busybox ash,
    # and POSIX mode is the check that catches "correct in bash, fatal
    # on the target". defaults.sh pins the shebangs so the two agree.
    # SC1091: we source lib.sh by a computed path; shellcheck cannot follow it.
    shellcheck -s sh -e SC1091 "$f" || rc=1
done

# shellcheck disable=SC2086
for f in $_test_candidates; do
    [ -f "$f" ] || continue
    head -n 1 "$f" | grep -q '^#!.*sh' || continue
    printf '  %s\n' "${f#"$LAYER"/}"
    shellcheck -e SC1091 "$f" || rc=1
done

# The gate must have checked the shipped scripts, not just the tests. Zero here
# means the selection above stopped matching them — a silent loss of the only
# check that catches "correct in bash, fatal on busybox".
# ── A LAYER MAY LEGITIMATELY SHIP NO SHELL — BUT IT MUST SAY SO ────────────
# After the repo split, a pure package layer (recipes only, no units) reaches
# this guard with a count of zero through no fault of its own. Silently
# tolerating that would dissolve the guard for every layer, which is exactly the
# failure it was written to prevent.
#
# So the absence must be DECLARED: set LINT_EXPECT_UNITS=0 in tests/topology.sh.
# A repo that ships units and loses them still fails, because it never declared
# that it had none.
if [ "$units_linted" -eq 0 ] && [ "${LINT_EXPECT_UNITS:-}" = "0" ]; then
    printf '  (0 shipped unit scripts — declared by tests/topology.sh, not inferred)\n'
elif [ "$units_linted" -eq 0 ]; then
    printf '\nlint FAILED: no unit scripts were checked at all.\n'
    printf '  If this layer genuinely ships none, declare it:\n'
    printf '    LINT_EXPECT_UNITS=0   # in tests/topology.sh\n'
    printf '  UNITS=%s\n' "$UNITS"
    printf '  UNITS_NESTED=%s\n' "$UNITS_NESTED"
    printf '  The shipped scripts are what matter here; linting only the test\n'
    printf '  files is worse than useless because it still exits 0.\n'
    exit 1
fi
[ "$units_linted" -gt 0 ] && printf '  (%d shipped unit scripts checked)\n' "$units_linted"

if [ "$rc" -ne 0 ]; then
    printf '\nlint FAILED\n'
    exit 1
fi
printf '\nlint OK\n'
