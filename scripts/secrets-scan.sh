#!/usr/bin/env bash
# Secret scan (CLAUDE.md 13.3): the entire git history plus the current state of all tracked files.
# Ignored files (.secrets/, config.env, upstream/) are deliberately out of scope — they never enter git.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

command -v gitleaks >/dev/null || die "gitleaks not installed" "run: make prereqs"
cd "$CFKD_ROOT"

gitleaks git . --redact --no-banner --exit-code 1 || die "secret found in git history" "do not push; rewrite history (CLAUDE.md 13.3)"
log_ok "git history: no secrets"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$work"
gitleaks dir "$work" --redact --no-banner --exit-code 1 || die "secret found in tracked files (working tree)" "remove it before committing"
log_ok "tracked files (working tree): no secrets"
