#!/usr/bin/env bash
# cf CLI with a project-local CF_HOME (~/.cf of other foundations stays untouched).
#   scripts/cf.sh login       log in as ccadmin (password from upstream/temp/secrets.sh, never in argv)
#   scripts/cf.sh bootstrap   org/space "test", feature flags, buildpacks (upstream make bootstrap)
#   scripts/cf.sh smoke       push hello-js and call it via HTTPS
#   scripts/cf.sh cf …        any cf command
set -euo pipefail

# shellcheck source=upstream.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream.sh"

cf_api_url() { echo "https://api.$SYSTEM_DOMAIN"; }
smoke_url() { echo "https://$1.$APPS_DOMAIN"; }

# Only a publicly trusted certificate (Let's Encrypt prod) works without --skip-ssl-validation
cf_ssl_flag() {
  if [[ "$DOMAIN" != "$NIP_DOMAIN" && "$TLS_MODE" == "letsencrypt" && "$ACME_ENV" == "prod" ]]; then echo ""
  else echo "--skip-ssl-validation"; fi
}

cmd_login() {
  load_config
  use_project_cf_home
  local secrets="$UPSTREAM_DIR/temp/secrets.sh" api
  [[ -f "$secrets" ]] || die "$secrets missing — is Cloud Foundry installed?" "run: make up"
  api="$(cf_api_url)"
  log_info "waiting for $api"
  curl -ksf --retry 30 --retry-delay 5 --retry-all-errors --max-time 10 --resolve "api.$SYSTEM_DOMAIN:443:127.0.0.1" "$api/v3/info" >/dev/null \
    || die "CF API $api not responding" "run: make status; make kubectl ARGS=\"get pods -A\""
  # shellcheck disable=SC2046
  cf api "$api" $(cf_ssl_flag) >/dev/null
  # pass the password to `cf auth` via the environment, not via argv
  (
    # shellcheck source=/dev/null
    source "$secrets"
    CF_USERNAME=ccadmin CF_PASSWORD="$CC_ADMIN_PASSWORD" cf auth >/dev/null
  )
  log_ok "logged in as ccadmin at $api (CF_HOME=$CF_HOME)"
}

cmd_bootstrap() {
  upstream_make bootstrap
  log_ok "org/space test and buildpacks ready"
}

cmd_smoke() {
  load_config
  use_project_cf_home
  local app="hello-js" url
  cf push -f "$UPSTREAM_DIR/examples/hello-js/manifest.yaml"
  url="$(smoke_url "$app")"
  if curl -ksf --max-time 10 --resolve "$app.$APPS_DOMAIN:443:127.0.0.1" "$url" >/dev/null; then log_ok "$url responds (HTTP 200)"
  else die "$url not responding" "run: make cf ARGS=\"logs $app --recent\""; fi
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    login) cmd_login ;;
    bootstrap) load_config; cmd_bootstrap ;;
    smoke) cmd_smoke ;;
    cf) use_project_cf_home; exec cf "$@" ;;
    *) die "unknown command '$cmd'" "usage: scripts/cf.sh login|bootstrap|smoke|cf …" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
