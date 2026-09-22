#!/usr/bin/env bash
# Gateway certificate for custom domains (CLAUDE.md 9.3): secret "public-tls" in cf-system.
#   scripts/tls.sh ensure    obtain the certificate (Let's Encrypt or from the upstream CA) and install it as a secret
# Without a custom domain the upstream certificate all-in-one-tls (127-0-0-1.nip.io) stays — then ensure does nothing.
set -euo pipefail

# shellcheck source=certs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs.sh"

UPSTREAM_DIR="${UPSTREAM_DIR:-$CFKD_ROOT/upstream}"
GATEWAY_SECRET="public-tls"
GATEWAY_NAMESPACE="cf-system"

needs_public_tls() { [[ "$DOMAIN" != "$NIP_DOMAIN" ]]; }

gateway_cert_source() {
  if [[ "$TLS_MODE" == "letsencrypt" ]]; then cert_store
  else echo "$CFKD_HOME/certs/selfsigned/$DOMAIN"; fi
}

# issue_from_ca CA_CRT CA_KEY "SAN…" OUT_DIR — certificate for the demo domain, signed by the upstream CA
issue_from_ca() {
  local ca_crt="$1" ca_key="$2" sans="$3" out="$4" work cn s san_ext=""
  local -a san_list
  read -r -a san_list <<<"$sans"
  for s in "${san_list[@]}"; do san_ext="${san_ext:+$san_ext,}DNS:$s"; done
  cn="${san_list[0]#\*.}"
  work="$(mktemp -d)"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$work/privkey.pem" -out "$work/req.csr" -subj "/CN=$cn" >/dev/null 2>&1
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$san_ext" > "$work/ext.cnf"
  openssl x509 -req -in "$work/req.csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial -days 180 -sha256 \
    -extfile "$work/ext.cnf" -out "$work/cert.pem" >/dev/null 2>&1
  cat "$work/cert.pem" "$ca_crt" > "$work/fullchain.pem"
  mkdir -p "$work/final"
  cp "$work/fullchain.pem" "$work/privkey.pem" "$work/final/"
  install_issued_cert "$work/final" "$out"
  rm -rf "$work"
}

install_gateway_secret() {
  local src="$1"
  use_project_kubeconfig
  kubectl create namespace "$GATEWAY_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$GATEWAY_NAMESPACE" create secret tls "$GATEWAY_SECRET" \
    --cert="$src/fullchain.pem" --key="$src/privkey.pem" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log_ok "gateway certificate installed: $GATEWAY_NAMESPACE/$GATEWAY_SECRET ($(cert_days_left "$src/fullchain.pem") days)"
}

cmd_ensure() {
  if ! needs_public_tls; then
    log_ok "no custom domain — gateway uses the upstream certificate ($NIP_DOMAIN)"
    return 0
  fi
  local src; src="$(gateway_cert_source)"
  if [[ "$TLS_MODE" == "letsencrypt" ]]; then
    cmd_issue
  else
    local ca="$UPSTREAM_DIR/temp/certs"
    [[ -f "$ca/ca.crt" && -f "$ca/ca.key" ]] || die "upstream CA missing ($ca)" "run: make up (init creates the CA)"
    if [[ -n "$(renewal_reason "$src/fullchain.pem" "$CERT_SANS" "$RENEW_DAYS")" ]]; then
      issue_from_ca "$ca/ca.crt" "$ca/ca.key" "$CERT_SANS" "$src"
      log_ok "self-signed certificate for $DOMAIN issued by the upstream CA"
    fi
  fi
  install_gateway_secret "$src"
}

main() {
  load_config
  case "${1:-}" in
    ensure) cmd_ensure ;;
    *) die "unknown command '${1:-}'" "usage: scripts/tls.sh ensure" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
