#!/bin/sh
# Every mutation in tests/mutations.conf must turn its case RED.
#
# A test that stays green after the behaviour it guards is broken is
# decoration. This runner copies the repo (minus .git) into a scratch tree,
# applies ONE row's sed expression to ONE shipped file there, and runs the
# named case from the copy — tests/topology.sh derives every path from the
# case file's own location, so the copy is self-contained and nothing here
# needs a seam. A row passes when the case reports at least one failure (or
# dies); it fails when the case stays green, and when the sed changed
# nothing, because a mutation that does not apply proves nothing.
#
#   sh tests/mutate.sh                   every row
#   sh tests/mutate.sh wittypi-daemon    only rows whose case is wittypi-daemon
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/.." && pwd)
want="${1:-}"
rows=0; red=0; bad=0
while IFS='|' read -r file expr case; do
    file=$(printf '%s' "$file" | sed 's/^ *//;s/ *$//')
    expr=$(printf '%s' "$expr" | sed 's/^ *//;s/ *$//')
    case=$(printf '%s' "$case" | sed 's/^ *//;s/ *$//')
    case "$file" in ''|'#'*) continue ;; esac
    [ -n "$want" ] && [ "$want" != "$case" ] && continue
    rows=$(( rows + 1 ))
    W=$(mktemp -d "${TMPDIR:-/tmp}/wittypi-mutate.XXXXXX")
    ( cd "$REPO" && tar cf - --exclude=.git . ) | ( cd "$W" && tar xf - )
    if ! sed "$expr" "$REPO/$file" > "$W/$file" 2>"$W/sed.err"; then
        printf '  ERROR %-34s sed failed — %s\n' "$file" "$(cat "$W/sed.err")"; bad=$(( bad + 1 )); rm -rf "$W"; continue
    fi
    if cmp -s "$REPO/$file" "$W/$file"; then
        printf '  ERROR %-34s the mutation changed nothing: %s\n' "$file" "$expr"; bad=$(( bad + 1 )); rm -rf "$W"; continue
    fi
    out=$(sh "$W/tests/cases/$case.sh" 2>&1); rc=$?
    fails=$(printf '%s\n' "$out" | sed -n 's/^__COUNTS__ [0-9]* \([0-9]*\)$/\1/p' | tail -n 1)
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    if [ "$fails" -gt 0 ]; then
        printf '  red   %-34s %-22s %s failure(s)\n' "$file" "$case" "$fails"; red=$(( red + 1 ))
    elif [ "$rc" -ne 0 ]; then
        printf '  red   %-34s %-22s the case died (exit %s)\n' "$file" "$case" "$rc"; red=$(( red + 1 ))
    else
        printf '  GREEN %-34s %-22s stayed green after: %s\n' "$file" "$case" "$expr"; bad=$(( bad + 1 ))
    fi
    rm -rf "$W"
done < "$HERE/mutations.conf"
printf '\nmutate: %s row(s), %s red, %s not red\n' "$rows" "$red" "$bad"
[ "$bad" -eq 0 ] && [ "$rows" -gt 0 ]
