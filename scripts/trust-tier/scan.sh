#!/usr/bin/env bash
# Leak guard for this PUBLIC repo. Shared by the local pre-push hook
# (scripts/git-hooks/pre-push) and the GitHub Actions backstop
# (.github/workflows/trust-tier-guard.yaml) so both enforce identical rules.
#
# Design note: this scanner contains ONLY GENERIC structural patterns — the
# shapes that private infrastructure leaks take (RFC1918 addresses, reserved /
# internal DNS suffixes). It deliberately holds NO specific domain, hostname, or
# identifier — nothing here ties back to any particular network. Catching a
# specific apex domain or hostname is the job of the publishing agent's PRIVATE
# scrubber (kept outside this repo) plus its prompt discipline; this file is the
# generic, publishable net.
#
# Checks:
#   1. structural infra shapes in commit MESSAGES (range mode)
#   2. structural infra shapes in file CONTENT (added lines / whole tree)
#   3. SECRETS in content — gitleaks (optional; used when available)
#
# Usage:
#   scan.sh <git-range>     e.g. scan.sh origin/main..HEAD   (range mode)
#   scan.sh                 no range → whole-tree content scan, no messages
#
# Exit 0 = clean, 1 = at least one finding (detail on stderr).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
RANGE="${1:-}"
rc=0

# Generic structural patterns (extended regex). No specific identifiers.
PATTERNS=(
  '\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b'                 # RFC1918 10/8
  '\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b'     # RFC1918 172.16/12
  '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b'                       # RFC1918 192.168/16
  '\b[a-z0-9-]+\.home\.arpa\b'                                 # RFC8375 reserved home suffix
  '\b[a-z0-9-]+\.(internal|intranet|lan|localdomain)\b'        # common internal suffixes
)

note() { printf '%s\n' "$*" >&2; }
fail() { printf '✗ %s\n' "$*" >&2; rc=1; }

# Exclude this scanner (it documents the very shapes it matches → self-trip) and
# SOPS payloads.
excludes=(
  ':(exclude)scripts/trust-tier/*'
  ':(exclude)*.sops.yaml' ':(exclude)*.sops.yml' ':(exclude)*.sops.json'
)

# ── 1. commit messages (range mode only) ─────────────────────────────────────
if [ -n "$RANGE" ]; then
  note "→ commit-message structural scan ($RANGE)…"
  msgs="$(git -C "$ROOT" log --no-merges --format='%H%n%B' "$RANGE" 2>/dev/null || true)"
  for pat in "${PATTERNS[@]}"; do
    hit="$(printf '%s' "$msgs" | grep -Eio "$pat" | head -1 || true)"
    [ -n "$hit" ] && fail "commit message contains a private-infra shape '$hit'"
  done
fi

# ── 2. file content ──────────────────────────────────────────────────────────
note "→ content structural scan…"
if [ -n "$RANGE" ]; then
  added="$(git -C "$ROOT" diff "$RANGE" -- . "${excludes[@]}" | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
else
  added="$(git -C "$ROOT" grep -hI -nE '.' -- . "${excludes[@]}" 2>/dev/null || true)"
fi
for pat in "${PATTERNS[@]}"; do
  hit="$(printf '%s' "$added" | grep -Eio "$pat" | head -1 || true)"
  [ -n "$hit" ] && fail "tracked content contains a private-infra shape '$hit'"
done

# ── 3. gitleaks (secrets) — optional ─────────────────────────────────────────
if command -v gitleaks >/dev/null 2>&1; then GL=(gitleaks)
elif command -v mise >/dev/null 2>&1 && mise exec -- gitleaks version >/dev/null 2>&1; then GL=(mise exec -- gitleaks)
else GL=(); fi

if [ ${#GL[@]} -gt 0 ]; then
  note "→ gitleaks (secrets)…"
  glargs=(detect --no-banner --redact --source "$ROOT")
  [ -f "$ROOT/.gitleaks.toml" ] && glargs+=(--config "$ROOT/.gitleaks.toml")
  if [ -n "$RANGE" ]; then
    "${GL[@]}" "${glargs[@]}" --log-opts="$RANGE" || fail "gitleaks found secret material in $RANGE"
  else
    "${GL[@]}" "${glargs[@]}" || fail "gitleaks found secret material in the worktree"
  fi
else
  note "→ gitleaks not found — skipping secret scan (install for full coverage)"
fi

if [ "$rc" -eq 0 ]; then note "✓ leak guard clean"; fi
exit "$rc"
