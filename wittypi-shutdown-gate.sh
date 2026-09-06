#!/bin/sh
# /etc/profile.d/wittypi-shutdown-gate.sh — the interactive-shell layer of the
# shutdown gate.
#
# SOURCED by /etc/profile for login shells, never executed — the shebang is
# here so tests/lint.sh's shebang-selected shellcheck gate covers this file.
# An integrator installing this should assert that /etc/profile really does
# iterate profile.d: a drop-in nothing reads is not a safety layer, it is a
# comment.
#
# The binary-replacement half of the gate cannot see `systemctl poweroff` —
# the full verb, typed directly, reaches /usr/bin/systemctl without touching
# /usr/sbin. This function closes exactly the failure mode the design names:
# someone tired, manually, at a shell. It is NOT a technical guarantee — a
# script calling /usr/bin/systemctl by absolute path bypasses it (functions
# only shadow simple command names), and that is the accepted, user-approved
# scope; the bounded 26 h guaranteed-wake backstop covers the remainder.
#
# The match is deliberately cheap — "is poweroff or halt among the args" —
# and safe to overtrigger: the gate re-parses the argv properly (only the
# VERB position gates) and then execs /usr/bin/systemctl with the original
# arguments untouched, so a false positive costs one process hop and
# changes nothing. reboot is never matched: it stays ungated by design.
#
# Interactive shells only. A login shell running a script (`sh -l -c ...`)
# has no tired human at it, and scripts must see the real systemctl.
case "$-" in
    *i*)
        systemctl() {
            for _tsg in "$@"; do
                case "$_tsg" in
                    poweroff|halt)
                        unset _tsg
                        /usr/libexec/site/wittypi-shutdown-gate "$@"
                        return
                        ;;
                esac
            done
            unset _tsg
            /usr/bin/systemctl "$@"
        }
        ;;
esac
