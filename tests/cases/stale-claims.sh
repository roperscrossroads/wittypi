#!/bin/sh
# Claims that were once true, or never were, stay out of the shipped files.
#
# Each one below misled a reader of this code into a wrong conclusion about the
# controller or the boot order (audit, 2026-09-15). A comment that contradicts
# the code costs more than no comment: it is believed.
. "$(dirname "$0")/../lib.sh"
R=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
# Comments wrap, so a phrase can straddle lines: compare the text with comment
# markers stripped and whitespace collapsed.
flat() { sed 's/^[[:space:]]*#[[:space:]]*//' "$1" | tr '\n' ' ' | tr -s ' '; }

describe "the daemon writes after a halt request, and the schedule unit says so"
t=$(flat "$R/systemd/wittypi-schedule.service")
assert_not_contains "$t" "the daemon never writes a register" "no 'daemon never writes' claim"
assert_contains "$t" "wake-guard ensure" "names the write the daemon does make"

describe "the scheduler's start timeout is quoted as the unit sets it"
u=$(sed -n 's/^TimeoutStartSec=//p' "$R/systemd/wittypi-schedule.service")
assert_eq "60" "$u" "wittypi-schedule.service TimeoutStartSec is 60"
for f in wittypi-schedule wittypi-watch; do
    assert_not_contains "$(flat "$R/$f")" "TimeoutStartSec=30" "$f does not quote 30"
done

describe "a past alarm1 is described for both of its cases"
w=$(flat "$R/wittypi-watch")
assert_not_contains "$w" "so that state self-heals" "no blanket 'self-heals' for a past alarm1"
assert_contains "$w" "STARTED this boot is not remembered" "the wake that started this boot is not re-fired"

describe "WITTYPI.md shows the clock unit before configure, as the units order it"
blk=$(awk '/^## The systemd units — a reference shape/{f=1} f&&/^```$/{c++; if(c==2) exit; next} f&&c==1' "$R/WITTYPI.md")
clock=$(printf '%s\n' "$blk" | grep -n 'wittypi-clock.service' | cut -d: -f1)
conf=$(printf '%s\n' "$blk" | grep -n 'wittypi-configure.service' | cut -d: -f1)
if [ -n "$clock" ] && [ -n "$conf" ] && [ "$clock" -lt "$conf" ]; then ok "clock ($clock) before configure ($conf)"; else notok "clock before configure" "clock=$clock configure=$conf"; fi
assert_contains "$(cat "$R/systemd/wittypi-clock.service")" "Before=wittypi-configure.service" "and the clock unit really is Before=configure"
