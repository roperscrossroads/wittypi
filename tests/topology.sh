# What this repo owns. Sourced by BOTH tests/lib.sh and tests/lint.sh.
#
# Those two callers name the repo root differently — lib.sh sets LAYER_DIR,
# lint.sh sets LAYER — and lint.sh runs under `set -u`, so referring to the
# wrong one is not a fallback, it is an immediate abort. Normalise first.
_ROOT="${LAYER_DIR:-${LAYER:-}}"
[ -n "$_ROOT" ] || _ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Every shipped script lives flat at the repo root: the driver (wittypi,
# wittypi-lib.sh, wittypi-daemon, wittypi-before-shutdown) and the supervisor
# layered on it (wittypi-watch, wittypi-schedule, wittypi-audit,
# wittypi-shutdown-gate, timing-windows/-terms) alike.
#
# RPI_UNITS_DIR and OPS_UNITS_DIR are the same directory now, and both names
# are historical: they come from the layer this was extracted from, where the
# driver was a recipe under a nested Pi layer and the supervisor a separate
# recipe beside it. The two halves are one repo, so the distinction is gone —
# the names are kept only because the cases are written against them.
RPI_DIR="$_ROOT"
RPI_UNITS_DIR="$_ROOT"
OPS_UNITS_DIR="$_ROOT"

# All systemd units, driver and supervisor, in one conventional subdirectory —
# a flat root for plain files plus systemd/ for units, rather than the Yocto
# recipes-*/*/files/ nesting this was extracted from.
RPI_SYSTEMD_DIR="$_ROOT/systemd"

# UNITS_DIR, RK3506_DIR and PYDIR stay UNSET: this repo is the controller and
# its supervisor, nothing else. The site integration (wake-guard, notify), the
# BSP and board layers, the image recipes and any python recipes live
# elsewhere. Cases needing them SKIP visibly via need_dir/have rather than
# failing — see tests/lib.sh.
LINT_ROOTS="$_ROOT"
