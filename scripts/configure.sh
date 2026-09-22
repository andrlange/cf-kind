#!/usr/bin/env bash
# Pre-task: writes config.env (domain, TLS mode, provider …) and shows the derived values.
#   scripts/configure.sh KEY=VALUE [KEY=VALUE ...]   set values (an invalid configuration is discarded)
#   scripts/configure.sh --show                      show current + derived configuration
#   scripts/configure.sh                             interactive (terminal only)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# set_config_value FILE KEY VALUE — replaces the line KEY=… or appends it.
set_config_value() {
  local file="$1" key="$2" value="$3" tmp
  touch "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=\"" v "\""; done = 1; next }
    { print }
    END { if (!done) print k "=\"" v "\"" }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

is_config_key() {
  local k
  for k in $CONFIG_KEYS; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

show_config() {
  load_config
  local k
  printf '# configuration (%s)\n' "$CFKD_CONFIG"
  for k in $CONFIG_KEYS; do printf '  %-22s %s\n' "$k" "${!k}"; done
  printf '# derived\n'
  for k in SYSTEM_DOMAIN APPS_DOMAIN BLOBSTORE_DOMAIN CERT_SANS RESOLVER_DOMAINS; do printf '  %-22s %s\n' "$k" "${!k}"; done
}

# Validates the file without influence from environment variables.
validate_file() {
  (
    for k in $CONFIG_KEYS; do unset "$k"; done
    unset _CFKD_OVERRIDES_CAPTURED
    load_config
    validate_config
  )
}

apply_assignments() {
  local arg key value
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || die "argument '$arg' is not of the form KEY=VALUE"
    key="${arg%%=*}" value="${arg#*=}"
    is_config_key "$key" || die "unknown key '$key'" "allowed: $CONFIG_KEYS"
    [[ "$value" =~ ^[A-Za-z0-9._@:/~+-]*$ ]] || die "value for $key contains forbidden characters: '$value'" "allowed: letters, digits and . _ @ : / ~ + -"
  done

  local backup=""
  if [[ -f "$CFKD_CONFIG" ]]; then backup="$(mktemp "${CFKD_CONFIG}.bak.XXXXXX")"; cp "$CFKD_CONFIG" "$backup"; fi

  for arg in "$@"; do set_config_value "$CFKD_CONFIG" "${arg%%=*}" "${arg#*=}"; done

  local problems
  if ! problems="$(validate_file)"; then
    if [[ -n "$backup" ]]; then mv "$backup" "$CFKD_CONFIG"; else rm -f "$CFKD_CONFIG"; fi
    printf '%s\n' "$problems" | while IFS= read -r line; do log_error "$line"; done
    die "configuration discarded, $CFKD_CONFIG is unchanged" "fix the values and rerun: make configure KEY=VALUE"
  fi
  [[ -n "$backup" ]] && rm -f "$backup"
  log_ok "configuration saved: $CFKD_CONFIG"
}

interactive() {
  load_config
  local answers=() v
  _ask() { # _ask KEY "question" DEFAULT
    read -r -p "$2 [$3]: " v
    answers+=("$1=${v:-$3}")
  }
  _ask K8S_PROVIDER "Kubernetes base (kind|k3d)" "$K8S_PROVIDER"
  _ask TLS_MODE "TLS mode (selfsigned|letsencrypt)" "$TLS_MODE"
  local current_domain="$DOMAIN"; [[ "$current_domain" == "$NIP_DOMAIN" ]] && current_domain=""
  _ask DOMAIN "Domain (empty = $NIP_DOMAIN)" "$current_domain"
  _ask DOMAIN_LAYOUT "Layout (split = sys./app. | flat = single level)" "$DOMAIN_LAYOUT"
  if [[ "${answers[1]#*=}" == "letsencrypt" ]]; then
    _ask DNS_ZONE "DNS zone" "$DNS_ZONE"
    _ask ACME_EMAIL "Email for Let's Encrypt" "${ACME_EMAIL:-admin@$DNS_ZONE}"
  fi
  unset -f _ask
  apply_assignments "${answers[@]}"
}

main() {
  if [[ "${1:-}" == "--show" ]]; then show_config; return; fi
  if [[ $# -gt 0 ]]; then apply_assignments "$@"; show_config; return; fi
  [[ -t 0 ]] || die "no values given" "run: make configure KEY=VALUE … (e.g. TLS_MODE=letsencrypt DOMAIN=kind.cfapps.cool ACME_EMAIL=admin@cfapps.cool)"
  interactive
  show_config
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
