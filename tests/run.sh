#!/bin/sh
# Run the unit-script tests. No privileges, no network, no board.
#
#   ./tests/run.sh              run everything
#   ./tests/run.sh slot-health  run one case file (basename, no .sh)
#
# Exits non-zero if any assertion fails, so it can gate a commit or a build.
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
want="${1:-}"

total_pass=0
total_fail=0
files=0

for case_file in "$HERE"/cases/*.sh; do
    [ -f "$case_file" ] || continue
    name=$(basename "$case_file" .sh)
    [ -n "$want" ] && [ "$want" != "$name" ] && continue
    files=$(( files + 1 ))

    printf '\n== %s\n' "$name"
    # Each case prints its own ok/FAIL lines and a trailing counts line that we
    # parse. Running them in separate processes keeps one case's fixtures and
    # exported tunables from leaking into the next.
    out=$(sh "$case_file" 2>&1)
    rc=$?
    printf '%s\n' "$out" | grep -v '^__COUNTS__'

    # A case that dies is not a case that passed.
    # This can happen for real: a shell syntax error half way down a case
    # file. The assertions above it had already run and emitted their
    # counts, the EXIT trap dutifully printed them, and this runner would
    # report a clean pass for a file whose second half never executed.
    #
    # The zero-assertion guard below does not catch it either: three is not
    # zero. Only the exit status distinguishes "finished" from "stopped".
    if [ "$rc" -ne 0 ]; then
        printf '    DIED %s exited %d — assertions after that point never ran\n' "$name" "$rc"
        total_fail=$(( total_fail + 1 ))
    fi

    counts=$(printf '%s\n' "$out" | sed -n 's/^__COUNTS__ //p')
    p=$(printf '%s' "$counts" | cut -d' ' -f1)
    f=$(printf '%s' "$counts" | cut -d' ' -f2)
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    case "$f" in ''|*[!0-9]*) f=0 ;; esac
    total_pass=$(( total_pass + p ))
    total_fail=$(( total_fail + f ))
done

if [ "$files" -eq 0 ]; then
    printf 'no case files matched %s\n' "${want:-*}" >&2
    exit 2
fi

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed, across %d case file(s)\n' "$total_pass" "$total_fail" "$files"

if [ "$total_fail" -gt 0 ]; then
    printf 'FAILED\n'
    exit 1
fi

# Zero passes is not success. In a combined tree this could only happen via
# the EXIT-trap bug (see lib.sh) — rare, and already documented. Once
# packages are split across repos it has a second, routine cause: a repo
# whose tests/topology.sh does not set a variable some case needs, so every
# case need_dir-SKIPs and the run reports "0 passed ... OK".
#
# That is the same failure shape lint.sh already guards against by asserting a
# non-zero count of linted scripts, for the same reason: a gate that reports
# success while checking nothing trains you to ignore it.
#
# SKIPs are legitimate — a package layer has no units to test. But a run where
# NOTHING asserted anything is a misconfiguration, not a pass.
if [ "$total_pass" -eq 0 ]; then
    printf 'FAILED — 0 assertions ran. Every case SKIPped or died.\n' >&2
    printf 'Check tests/topology.sh: a variable some case needs is unset.\n' >&2
    exit 1
fi
printf 'OK\n'
