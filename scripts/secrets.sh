#!/usr/bin/env bash
# DNS provider credentials for Let's Encrypt (DNS-01), default: GCP service account key in the macOS keychain.
#   scripts/secrets.sh set-dns FILE [--delete-source]   validate the key and store it in the keychain
#   scripts/secrets.sh check-dns                        check that credentials are present (prints nothing secret)
# The secret never appears in argv, logs or the repo. get_dns_credentials is meant only for other scripts (phase 3).
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

validate_sa_json() {
  [[ -f "$1" ]] || return 1
  jq -e '.type == "service_account" and (.client_email | type == "string") and (.private_key | type == "string") and (.project_id | type == "string")' "$1" >/dev/null 2>&1
}

# prints "keychain:<service>" or an absolute file path (relative paths are relative to the project root)
dns_credentials_source() {
  local src="${ACME_DNS_CREDENTIALS:-}"
  case "$src" in
    keychain:*) echo "$src" ;;
    \~/*) echo "$HOME/${src#\~/}" ;;
    /*) echo "$src" ;;
    *) echo "$CFKD_ROOT/$src" ;;
  esac
}

keychain_service() {
  local src; src="$(dns_credentials_source)"
  [[ "$src" == keychain:* ]] || die "ACME_DNS_CREDENTIALS='$src' is not a keychain reference" "run: make configure ACME_DNS_CREDENTIALS=keychain:cf-kind-demo-gcp-dns"
  echo "${src#keychain:}"
}

set_dns() {
  local file="$1" svc
  validate_sa_json "$file" || die "$file is not a GCP service account key (type=service_account)" "create a key: gcloud iam service-accounts keys create … (CLAUDE.md 9.4)"
  svc="$(keychain_service)"
  # via stdin to `security -i` so the key does not show up in the process list; hex avoids quoting problems
  printf 'add-generic-password -U -a "%s" -s "%s" -l "%s" -X %s\n' \
    "$USER" "$svc" "cf-kind-demo DNS-01 credentials" "$(xxd -p "$file" | tr -d '\n')" | security -i >/dev/null
  log_ok "service account $(jq -r .client_email "$file") saved in the keychain (service: $svc)"
}

get_dns_credentials() {
  local src; src="$(dns_credentials_source)"
  if [[ "$src" == keychain:* ]]; then
    local raw
    raw="$(security find-generic-password -a "$USER" -s "${src#keychain:}" -w 2>/dev/null)" || return 1
    # security -w prints non-printable data (e.g. with a newline) hex-encoded; JSON is never pure hex
    if [[ "$raw" =~ ^([0-9a-f]{2})+$ ]]; then xxd -r -p <<<"$raw"; else printf '%s\n' "$raw"; fi
  else
    cat "$src"
  fi
}

check_dns() {
  local src; src="$(dns_credentials_source)"
  if [[ "$src" == keychain:* ]]; then
    security find-generic-password -a "$USER" -s "${src#keychain:}" >/dev/null 2>&1 \
      || die "no DNS credentials in the keychain (service ${src#keychain:})" "run: make secrets-set-dns FILE=<service-account.json>"
    log_ok "DNS credentials present in the keychain (service ${src#keychain:})"
  else
    [[ -f "$src" ]] || die "DNS credentials file missing: $src" "run: make configure ACME_DNS_CREDENTIALS=<path>, or use the keychain"
    [[ "$(stat -f %Lp "$src")" == "600" ]] || die "$src must have permissions 0600" "run: chmod 600 $src"
    validate_sa_json "$src" || die "$src is not a GCP service account key"
    log_ok "DNS credentials file present: $src"
  fi
}

# zone_for_domain DOMAIN "<zone-name> <dns-name.>\n…" — longest matching zone
zone_for_domain() {
  local domain="$1." best="" best_len=0 name dns
  while read -r name dns; do
    [[ -n "$name" ]] || continue
    if [[ "$domain" == "$dns" || "$domain" == *".$dns" ]] && ((${#dns} > best_len)); then best="$name" best_len=${#dns}; fi
  done <<<"$2"
  echo "$best"
}

# Isolated gcloud session with the DNS service account: sets CLOUDSDK_CONFIG to a temp directory
# (the caller cleans it up). The user's own gcloud login stays untouched.
gcloud_sa_session() {
  command -v gcloud >/dev/null || die "gcloud missing" "run: brew install --cask gcloud-cli"
  check_dns >/dev/null
  CLOUDSDK_CONFIG="$(mktemp -d)"
  export CLOUDSDK_CONFIG
  (umask 077; get_dns_credentials > "$CLOUDSDK_CONFIG/sa.json")
  gcloud auth activate-service-account --key-file="$CLOUDSDK_CONFIG/sa.json" --quiet >/dev/null 2>&1 \
    || { rm -rf "$CLOUDSDK_CONFIG"; die "gcloud login with the service account failed"; }
  rm -f "$CLOUDSDK_CONFIG/sa.json"
}

gcloud_zone_for() {
  zone_for_domain "$1" "$(gcloud dns managed-zones list --project "$GCP_PROJECT" --format='value(name,dnsName)')"
}

main() {
  load_config
  case "${1:-}" in
    set-dns)
      [[ -n "${2:-}" ]] || die "file missing" "run: make secrets-set-dns FILE=<service-account.json>"
      set_dns "$2"
      if [[ "${3:-}" == "--delete-source" ]]; then rm -P "$2" 2>/dev/null || rm -f "$2"; log_ok "source file $2 deleted"
      else log_warn "source file $2 is still on disk" "delete it, or run: make secrets-set-dns FILE=… DELETE_SOURCE=1"; fi
      ;;
    check-dns) check_dns ;;
    *) die "unknown command '${1:-}'" "usage: scripts/secrets.sh set-dns FILE [--delete-source] | check-dns" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
