#!/usr/bin/env bash
# Let's Encrypt wildcard certificates via DNS-01 (lego) — certificates live on the host, not in the cluster (CLAUDE.md 9.5).
#   scripts/certs.sh issue    issue/renew when needed (missing, SANs changed, < RENEW_DAYS days left; FORCE_RENEW=1)
#   scripts/certs.sh status   show remaining validity and SANs
#   scripts/certs.sh autorenew [--remove]   install/remove the daily launchd job
# Storage: $CFKD_HOME/certs/<ACME_ENV>/<DOMAIN>/{fullchain.pem,privkey.pem}. New certificates are issued into a temp directory
# and swapped in only on success — a failed run leaves the old certificate untouched.
set -euo pipefail

# shellcheck source=secrets.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secrets.sh"

RENEW_DAYS="${RENEW_DAYS:-30}"
DNS_CHECK_RESOLVERS="8.8.8.8:53,1.1.1.1:53"

# lego does not check TXT propagation itself but waits a fixed time. Reason (observed 2026-09-22): demo Wi-Fi networks intercept
# outgoing DNS on port 53 — recursive resolvers return stale cached values, non-recursive queries to the
# authoritative name servers come back empty (no aa flag). Let's Encrypt validates from outside and is not affected.
lego_propagation_args() {
  echo "--dns.propagation.wait ${ACME_PROPAGATION_WAIT:-120s}"
}

# stale_challenge_records DOMAIN "<name>\t<type>\n…" — leftover _acme-challenge TXT records below DOMAIN
stale_challenge_records() {
  local domain="$1." name type
  while IFS=$'\t' read -r name type; do
    [[ "$type" == "TXT" && "$name" == _acme-challenge.* ]] || continue
    if [[ "$name" == "_acme-challenge.$domain" || "$name" == *".$domain" ]]; then echo "$name"; fi
  done <<<"$2"
}

lego_domain_args() {
  local -a san_list
  local out="" s
  read -r -a san_list <<<"$1"
  for s in "${san_list[@]}"; do out="$out -d $s"; done
  echo "${out# }"
}

acme_server() {
  case "$1" in
    prod) echo "https://acme-v02.api.letsencrypt.org/directory" ;;
    *) echo "https://acme-staging-v02.api.letsencrypt.org/directory" ;;
  esac
}

cert_store() { echo "$CFKD_HOME/certs/${ACME_ENV}/${DOMAIN}"; }

cert_days_left() {
  local end epoch
  end="$(openssl x509 -enddate -noout -in "$1" | sed 's/^notAfter=//' | tr -s ' ')"
  epoch="$(LC_ALL=C date -j -f "%b %d %T %Y %Z" "$end" +%s)"
  echo $(((epoch - $(date +%s)) / 86400))
}

cert_sans() {
  openssl x509 -noout -text -in "$1" | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ' | tr ',' '\n' | sed 's/^DNS://'
}

cert_covers_sans() {
  local have want s
  have="$(cert_sans "$1")"
  read -r -a want <<<"$2"
  for s in "${want[@]}"; do grep -qxF "$s" <<<"$have" || return 1; done
}

# prints missing | sans-changed | expiring | "" (nothing to do)
renewal_reason() {
  local file="$1" sans="$2" days="$3"
  if [[ ! -s "$file" ]]; then echo missing
  elif ! cert_covers_sans "$file" "$sans"; then echo sans-changed
  elif (($(cert_days_left "$file") < days)); then echo expiring
  else echo ""; fi
}

# install_issued_cert NEW_DIR STORE — atomic swap, only if fullchain.pem and privkey.pem are present
install_issued_cert() {
  local new="$1" store="$2" tmp
  [[ -s "$new/fullchain.pem" && -s "$new/privkey.pem" ]] || { log_error "incomplete certificate in $new"; return 1; }
  mkdir -p "$(dirname "$store")"
  tmp="$store.new.$$"
  rm -rf "$tmp"
  cp -R "$new" "$tmp"
  chmod 700 "$tmp"
  chmod 600 "$tmp/privkey.pem"
  if [[ -d "$store" ]]; then mv "$store" "$store.old.$$"; fi
  mv "$tmp" "$store"
  rm -rf "$store.old.$$"
}

cmd_issue() {
  [[ "$TLS_MODE" == "letsencrypt" ]] || { log_ok "TLS_MODE=$TLS_MODE — no Let's Encrypt certificates needed"; return 0; }
  local problems
  problems="$(validate_config)" || die "configuration invalid: $problems" "run: make configure KEY=VALUE"
  local store reason
  store="$(cert_store)"
  reason="$(renewal_reason "$store/fullchain.pem" "$CERT_SANS" "$RENEW_DAYS")"
  [[ "${FORCE_RENEW:-0}" == "1" && -z "$reason" ]] && reason="forced"
  if [[ -z "$reason" ]]; then
    log_ok "certificate current: $(cert_days_left "$store/fullchain.pem") days left ($ACME_ENV, $DOMAIN)"
    return 0
  fi
  [[ "$AIRGAP" == "true" ]] && die "certificate needs renewal ($reason), but AIRGAP=true" "go online and run: make certs"
  [[ "$ACME_DNS_PROVIDER" == "gcloud" ]] || die "ACME_DNS_PROVIDER=$ACME_DNS_PROVIDER is not implemented yet" "use: make configure ACME_DNS_PROVIDER=gcloud"
  check_dns >/dev/null

  local work lego_state
  work="$(mktemp -d)"
  lego_state="$CFKD_HOME/lego/$ACME_ENV"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  mkdir -p "$lego_state/accounts"
  chmod 700 "$CFKD_HOME/lego" "$lego_state"
  cp -R "$lego_state/accounts" "$work/" 2>/dev/null || true

  log_info "issuing certificate ($reason, $ACME_ENV): $CERT_SANS"
  # shellcheck disable=SC2046
  GCE_PROJECT="$GCP_PROJECT" GCE_SERVICE_ACCOUNT="$(get_dns_credentials)" GCE_PROPAGATION_TIMEOUT=300 \
    lego run --accept-tos --email "$ACME_EMAIL" --server "$(acme_server "$ACME_ENV")" \
    --dns gcloud --dns.resolvers "$DNS_CHECK_RESOLVERS" $(lego_propagation_args) --path "$work" --cert.name "$DOMAIN" \
    --log.format text $(lego_domain_args "$CERT_SANS") \
    || die "lego failed — the existing certificate is unchanged" "check the output above (DNS permissions, rate limits); test with ACME_ENV=staging first"

  local crt key
  crt="$(find "$work/certificates" -name "$DOMAIN.crt" | head -1)"
  key="$(find "$work/certificates" -name "$DOMAIN.key" | head -1)"
  [[ -n "$crt" && -n "$key" ]] || die "lego output lacks $DOMAIN.crt/.key in $work/certificates" "check the lego version (storage layout)"
  mkdir -p "$work/out"
  cp "$crt" "$work/out/fullchain.pem"
  cp "$key" "$work/out/privkey.pem"
  install_issued_cert "$work/out" "$store"
  rm -rf "$lego_state/accounts" && cp -R "$work/accounts" "$lego_state/"
  log_ok "certificate installed: $store ($(cert_days_left "$store/fullchain.pem") days, $ACME_ENV)"
}

# removes leftover challenge records (e.g. after an aborted lego run)
cmd_cleanup() {
  local zone rec n=0
  gcloud_sa_session
  # shellcheck disable=SC2064
  trap "rm -rf '$CLOUDSDK_CONFIG'" RETURN
  zone="$(gcloud_zone_for "$DOMAIN")"
  [[ -n "$zone" ]] || die "no Cloud DNS zone for $DOMAIN"
  while IFS= read -r rec; do
    gcloud dns record-sets delete "$rec" --type=TXT --zone="$zone" --project "$GCP_PROJECT" --quiet >/dev/null 2>&1
    log_ok "removed: TXT $rec"
    n=$((n + 1))
  done < <(stale_challenge_records "$DOMAIN" "$(gcloud dns record-sets list --zone="$zone" --project "$GCP_PROJECT" --format='value(name,type)' | tr ' ' '\t')")
  log_ok "$n challenge record(s) cleaned up"
}

cmd_status() {
  local store; store="$(cert_store)"
  printf 'TLS_MODE:  %s\nACME_ENV:  %s\nStorage:   %s\n' "$TLS_MODE" "$ACME_ENV" "$store"
  if [[ -s "$store/fullchain.pem" ]]; then
    printf 'Days left: %s\nSANs:\n' "$(cert_days_left "$store/fullchain.pem")"
    cert_sans "$store/fullchain.pem" | sed 's/^/  /'
    printf 'Issuer:    %s\n' "$(openssl x509 -noout -issuer -in "$store/fullchain.pem" | sed 's/^issuer= *//')"
  else
    echo "no certificate present — run: make certs"
  fi
}

RENEW_LABEL="io.cf-kind-demo.certs-renew"

# render_renew_plist BREW_BIN REPO LOG — daily at 09:15 and after login; without internet the run fails silently
# and the next day tries again (the old certificate survives thanks to the atomic swap).
render_renew_plist() {
  local brew_bin="$1" repo="$2" log="$3"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$RENEW_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>make -C $repo certs</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$brew_bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>15</integer>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
}

cmd_autorenew() {
  local plist="$HOME/Library/LaunchAgents/$RENEW_LABEL.plist"
  launchctl bootout "gui/$(id -u)/$RENEW_LABEL" >/dev/null 2>&1 || true
  if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$plist"
    log_ok "automatic renewal removed"
    return 0
  fi
  mkdir -p "$CFKD_HOME/logs" "$(dirname "$plist")"
  render_renew_plist "$(brew --prefix)/bin" "$CFKD_ROOT" "$CFKD_HOME/logs/certs-renew.log" > "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
  log_ok "automatic renewal active: daily at 09:15 (log: $CFKD_HOME/logs/certs-renew.log)"
}

main() {
  load_config
  case "${1:-}" in
    issue) cmd_issue ;;
    status) cmd_status ;;
    autorenew) cmd_autorenew "${2:-}" ;;
    cleanup) cmd_cleanup ;;
    *) die "unknown command '${1:-}'" "usage: scripts/certs.sh issue|status|autorenew [--remove]|cleanup" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
