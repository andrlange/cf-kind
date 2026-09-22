#!/usr/bin/env bash
# Orchestrates provider adapters and the upstream installation.
#   scripts/cluster.sh up       cluster (provider) + Cloud Foundry (upstream) + login + bootstrap
#   scripts/cluster.sh down     remove everything, image caches are kept
#   scripts/cluster.sh status   overview
set -euo pipefail

# shellcheck source=upstream.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream.sh"

PROVIDERS_DIR="${PROVIDERS_DIR:-$CFKD_ROOT/providers}"
PROVIDER_FUNCTIONS="provider_preflight provider_ensure provider_delete provider_kube_context provider_health"

load_provider() {
  local file="$PROVIDERS_DIR/$1.sh" f
  [[ -f "$file" ]] || die "provider '$1' not implemented ($file missing)" "run: make configure K8S_PROVIDER=kind"
  # shellcheck source=/dev/null
  source "$file"
  for f in $PROVIDER_FUNCTIONS; do
    declare -F "$f" >/dev/null || die "provider '$1' does not implement $f" "see the adapter interface: CLAUDE.md 4.4"
  done
}

cmd_up() {
  load_config
  load_provider "$K8S_PROVIDER"
  log_info "provider: $K8S_PROVIDER · system domain: $SYSTEM_DOMAIN · optional components: $CF_OPTIONAL_COMPONENTS"
  provider_preflight
  upstream_ensure
  provider_ensure
  upstream_make init
  "$CFKD_ROOT/scripts/tls.sh" ensure
  log_info "installing Cloud Foundry (helmfile sync, first run takes 5–20 min)"
  upstream_make install
  "$CFKD_ROOT/scripts/cf.sh" login
  "$CFKD_ROOT/scripts/cf.sh" bootstrap
  log_ok "Cloud Foundry running: $(cf_api_url_for "$SYSTEM_DOMAIN") — next: 'make smoke' or 'make cf ARGS=apps'"
}

cf_api_url_for() { echo "https://api.$1"; }

cmd_down() {
  load_config
  load_provider "$K8S_PROVIDER"
  provider_delete
  rm -rf "$UPSTREAM_DIR/temp" "$CFKD_HOME/cf/.cf"
  log_ok "environment removed (upstream checkout, image caches and local configuration are kept)"
}

cmd_status() {
  load_config
  load_provider "$K8S_PROVIDER"
  use_project_kubeconfig
  printf 'Provider:    %s (context %s)\nkubeconfig:  %s\nCF_HOME:     %s\nCF API:      %s\n' \
    "$K8S_PROVIDER" "$(provider_kube_context)" "$KUBECONFIG" "$CFKD_HOME/cf" "$(cf_api_url_for "$SYSTEM_DOMAIN")"
  provider_health || return 1
  local pending
  pending="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' | wc -l | tr -d ' ')"
  if [[ "$pending" == "0" ]]; then log_ok "all pods Running/Completed"; else log_warn "$pending pod(s) not Running — make kubectl ARGS=\"get pods -A\""; fi
  if curl -ksf --max-time 5 --resolve "api.$SYSTEM_DOMAIN:443:127.0.0.1" "$(cf_api_url_for "$SYSTEM_DOMAIN")/v3/info" >/dev/null; then log_ok "CF API responds"
  else log_error "CF API not responding"; return 1; fi
}

main() {
  case "${1:-}" in
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    *) die "unknown command '${1:-}'" "usage: scripts/cluster.sh up|down|status" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
