#!/usr/bin/env bash
# Language check (CLAUDE.md header): repository content must be English.
#   scripts/lint-language.sh   list lines that look German in tracked files (exit != 0 if any)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Umlauts/ß or frequent German words as whole words ("die" is excluded: bash helper + English word). URLs are stripped.  # lint-language: allow
GERMAN_PATTERN='[äöüÄÖÜß]|\b(und|oder|nicht|wird|werden|für|mit|der|das|den|dem|ist|sind|auf|bei|nach|oder|eine?|einen|keine?|nur|noch|auch|wenn|dann|bitte|prüfen|fehlt|konfiguration|gespeichert|erlaubt|vorhanden|entfernt|installiert|angemeldet|bereit|aktuell|datei|zertifikat|abgeleitet|weiter|beim|zum|zur|unter|befehl|unbekannte[rs]?|ungültig|läuft|erzeugt|angewendet|sich|kein|werte?|nutzt|braucht|gilt|siehe)\b'  # lint-language: allow

german_lines() {
  local f="$1"
  sed -E 's#https?://[^ )"]+##g' "$f" | grep -nE -i "$GERMAN_PATTERN" | grep -v 'lint-language: allow' | sed "s#^#$f:#" || true
}

main() {
  local f hits=0 out
  while IFS= read -r f; do
    out="$(german_lines "$f")"
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; hits=$((hits + $(wc -l <<<"$out"))); fi
  done < <(git -C "$CFKD_ROOT" ls-files | grep -vE '^(upstream/|patches/|docs/image-arch-report\.tsv)' | sed "s#^#$CFKD_ROOT/#")
  ((hits == 0)) || die "$hits line(s) look German" "translate them (CLAUDE.md: English everywhere)"
  log_ok "no German text found"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
