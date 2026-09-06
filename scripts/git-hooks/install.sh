#!/usr/bin/env bash
# Install repo-local git hooks. Idempotent.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/git-hooks/commit-msg scripts/git-hooks/pre-push scripts/trust-tier/scan.sh
ln -sfn ../../scripts/git-hooks/commit-msg .git/hooks/commit-msg
echo "✓ commit-msg hook installed → .git/hooks/commit-msg"
ln -sfn ../../scripts/git-hooks/pre-push .git/hooks/pre-push
echo "✓ pre-push hook installed → .git/hooks/pre-push (trust-tier guard)"
