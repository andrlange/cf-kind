#!/usr/bin/env bash
# Health checks and self-repair for the demo environment (CLAUDE.md chapter 10).
#   scripts/doctor.sh check    run all checks, exit != 0 if anything fails
#   scripts/doctor.sh repair   re-apply provider state (idempotent), gateway cert, then check again
set -euo pipefail

# shellcheck source=cluster.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster.sh"
# shellcheck source=tls.sh
source "$CFKD_ROOT/scripts/tls.sh"

MAX_CLOCK_DRIFT=60
N_OK=0 N_WARN=0 N_FAIL=0

report() { # report ok|warn|fail "<message>" ["<hint>"]
  case "$1" in
    ok) log_ok "$2"; N_OK=$((N_OK + 1)) ;;
    warn) log_warn "$2"; N_WARN=$((N_WARN + 1)) ;;
    fail) log_error "$2"; N_FAIL=$((N_FAIL + 1)) ;;
  esac
  if [[ "$1" != ok && -n "${3:-}" ]]; then printf '     -> %s\n' "$3" >&2; fi
  return 0
}

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

# subnets_overlap A/len B/len — true if one network contains (part of) the other
subnets_overlap() {
  local n1="${1%/*}" p1="${1#*/}" n2="${2%/*}" p2="${2#*/}" p mask
  p=$((p1 < p2 ? p1 : p2))
  mask=$(((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF))
  (($(($(ip_to_int "$n1") & mask)) == $(($(ip_to_int "$n2") & mask))))
}

# host_subnets < ifconfig output — IPv4 networks of the host, loopback excluded
host_subnets() {
  local line ip mask ipi maski bits
  while IFS= read -r line; do
    [[ "$line" =~ inet\ ([0-9.]+)\ netmask\ 0x([0-9a-f]{8}) ]] || continue
    ip="${BASH_REMATCH[1]}" mask="${BASH_REMATCH[2]}"
    [[ "$ip" == 127.* ]] && continue
    maski=$((16#$mask))
    bits=0
    while ((maski & 0x80000000)); do bits=$((bits + 1)); maski=$(((maski << 1) & 0xFFFFFFFF)); done
    ipi=$(($(ip_to_int "$ip") & (16#$mask)))
    echo "$(((ipi >> 24) & 255)).$(((ipi >> 16) & 255)).$(((ipi >> 8) & 255)).$((ipi & 255))/$bits"
  done
}

clock_drift() {
  local d=$(($1 - $2))
  echo "${d#-}"
}

cert_level() {
  if (($1 < 7)); then echo fail
  elif (($1 < 21)); then echo warn
  else echo ok; fi
}

check_config() {
  local problems
  if problems="$(validate_config)"; then report ok "configuration valid (provider $K8S_PROVIDER, system domain $SYSTEM_DOMAIN)"
  else report fail "configuration invalid: $problems" "make configure"; fi
}

# doctor checks a running stack, so the resolver should answer 127.0.0.1 (mode "active")
resolver_level() {
  if [[ "$1" == "active" ]]; then echo ok; else echo warn; fi
}

check_resolver() {
  local mode
  mode="$(sed -nE 's/^# mode=(active|passthrough)$/\1/p' "$CFKD_HOME/dnsmasq.conf" 2>/dev/null | head -1)"
  mode="${mode:-absent}"
  if ! "$CFKD_ROOT/scripts/dns.sh" check >/dev/null 2>&1; then
    report warn "local resolver not (fully) set up — names depend on public DNS" "run once: make dns"
    return 0
  fi
  report "$(resolver_level "$mode")" "local resolver mode: $mode ($DOMAIN)" "run: make dns-activate (or make repair)"
}

check_network_overlap() {
  local kind_net host
  kind_net="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1 || true)"
  [[ -n "$kind_net" ]] || { report ok "no docker network 'kind' yet"; return 0; }
  while IFS= read -r host; do
    if subnets_overlap "$kind_net" "$host"; then
      report fail "docker network kind ($kind_net) overlaps with host network $host (current Wi-Fi?)" "make down && make up (Phase 4 pins a rare subnet)"
      return 0
    fi
  done < <(ifconfig | host_subnets)
  report ok "docker network kind ($kind_net) does not overlap with host networks"
}

check_cluster() {
  load_provider "$K8S_PROVIDER"
  if provider_health >/dev/null 2>&1; then report ok "provider $K8S_PROVIDER healthy"
  else report fail "provider $K8S_PROVIDER not healthy" "make repair"; return 0; fi

  use_project_kubeconfig
  local pending
  pending="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"' | wc -l | tr -d ' ')"
  if [[ "$pending" == "0" ]]; then report ok "all pods Running/Completed"
  else report warn "$pending pod(s) not running" "make kubectl ARGS=\"get pods -A\""; fi

  if curl -ksf --max-time 5 --resolve "api.$SYSTEM_DOMAIN:443:127.0.0.1" "https://api.$SYSTEM_DOMAIN/v3/info" >/dev/null; then report ok "CF API answers (https://api.$SYSTEM_DOMAIN)"
  else report fail "CF API does not answer" "make repair"; fi

  if [[ "$K8S_PROVIDER" == "kind" ]]; then
    local node drift
    node="$(kind get nodes --name cfk8s 2>/dev/null | head -1)"
    if [[ -n "$node" ]]; then
      drift="$(clock_drift "$(date +%s)" "$(docker exec "$node" date +%s)")"
      if ((drift > MAX_CLOCK_DRIFT)); then report warn "clock drift host/node ${drift}s (UAA tokens may fail)" "docker desktop restart"
      else report ok "clock drift host/node ${drift}s"; fi
    fi
  fi
}

check_certificate() {
  needs_public_tls || { report ok "no own domain — upstream certificate in use"; return 0; }
  local src days
  src="$(gateway_cert_source)"
  if [[ ! -s "$src/fullchain.pem" ]]; then report fail "no gateway certificate for $DOMAIN" "make certs"; return 0; fi
  days="$(cert_days_left "$src/fullchain.pem")"
  report "$(cert_level "$days")" "gateway certificate valid for $days more days ($TLS_MODE${TLS_MODE:+/}$ACME_ENV)" "make certs FORCE_RENEW=1 (needs internet)"
}

check_global_configs() {
  if [[ -f "$HOME/.kube/config" ]] && grep -q "kind-cfk8s" "$HOME/.kube/config"; then
    report fail "$HOME/.kube/config contains the demo cluster (global config must stay untouched)" "kubectl config delete-context kind-cfk8s --kubeconfig ~/.kube/config"
  else
    report ok "$HOME/.kube/config untouched by cf-kind-demo"
  fi
}

cmd_check() {
  load_config
  check_config
  check_resolver
  check_network_overlap
  check_certificate
  check_global_configs
  check_cluster
  printf '\n%d ok, %d warn, %d fail\n' "$N_OK" "$N_WARN" "$N_FAIL" >&2
  ((N_FAIL == 0)) || die "doctor found problems" "follow the hints above, or try: make repair"
  log_ok "environment healthy"
}

cmd_repair() {
  load_config
  load_provider "$K8S_PROVIDER"
  log_info "re-applying provider state ($K8S_PROVIDER)"
  upstream_ensure
  provider_ensure
  cmd_ensure
  "$CFKD_ROOT/scripts/dns.sh" activate
  N_OK=0 N_WARN=0 N_FAIL=0
  cmd_check
}

main() {
  case "${1:-}" in
    check) cmd_check ;;
    repair) cmd_repair ;;
    *) die "unknown command '${1:-}'" "scripts/doctor.sh check|repair" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
