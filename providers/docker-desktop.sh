#!/usr/bin/env bash
# Provider adapter "docker-desktop" (CLAUDE.md 4.1): Docker Desktop's built-in Kubernetes in kind mode.
# Docker Desktop manages the cluster itself — there is no kind.yaml. Deviations from upstream are handled here and in
# patches/ (CNI=none, gateway as LoadBalancer). Loaded by scripts/cluster.sh via `source`.

# shellcheck source=../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib.sh"

DD_SETTINGS="${DD_SETTINGS:-$HOME/Library/Group Containers/group.com.docker/settings-store.json}"
DD_CONTEXT="docker-desktop"
DD_NODES="${DD_NODES:-3}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$CFKD_ROOT/upstream}"

# render_dd_settings FILE NODES VERSION — settings JSON with Kubernetes enabled in kind mode, everything else kept
render_dd_settings() {
  jq --argjson nodes "$2" --arg version "$3" \
    '.KubernetesEnabled = true | .KubernetesMode = "kind" | .KubernetesNodesCount = $nodes | .KubernetesNodesVersion = $version' "$1"
}

dd_k8s_matches() {
  jq -e --argjson nodes "$2" --arg version "$3" \
    '.KubernetesEnabled == true and .KubernetesMode == "kind" and .KubernetesNodesCount == $nodes and .KubernetesNodesVersion == $version' \
    "$1" >/dev/null 2>&1
}

# cell_node "<node names>" — the last worker becomes the Diego cell (upstream: 2nd worker carries the cell label)
cell_node() {
  grep -v control-plane <<<"$1" | sort | tail -1
}

provider_kube_context() { echo "$DD_CONTEXT"; }

_dd_status_field() {
  docker desktop kubernetes status 2>/dev/null | sed -nE "s/^$1:[[:space:]]+(.*)$/\\1/p" | head -1
}

_dd_wait_running() {
  local i state
  for ((i = 0; i < 120; i++)); do
    state="$(_dd_status_field State)"
    [[ "$state" == "running" ]] && return 0
    sleep 5
  done
  die "Docker Desktop Kubernetes did not reach state 'running' (last: ${state:-unknown})" "check Docker Desktop → Settings → Kubernetes"
}

_dd_enable_kubernetes() {
  local version
  version="$(_dd_status_field Version)"
  version="${version:-1.36.1}"
  if dd_k8s_matches "$DD_SETTINGS" "$DD_NODES" "$version" && [[ "$(_dd_status_field State)" == "running" ]]; then
    log_ok "Docker Desktop Kubernetes running (kind mode, $DD_NODES nodes, v$version)"
    return 0
  fi
  local backup tmp
  backup="$CFKD_HOME/backups/settings-store.$(date +%Y%m%d-%H%M%S).json"
  mkdir -p "$(dirname "$backup")"
  cp "$DD_SETTINGS" "$backup"
  log_info "enabling Docker Desktop Kubernetes (kind mode, $DD_NODES nodes, v$version) — Docker Desktop restarts; backup: $backup"
  docker desktop stop --timeout 180 >/dev/null
  tmp="$(mktemp)"
  render_dd_settings "$DD_SETTINGS" "$DD_NODES" "$version" > "$tmp"
  mv "$tmp" "$DD_SETTINGS"
  docker desktop start --timeout 300 >/dev/null
  _dd_wait_running
  log_ok "Docker Desktop Kubernetes running"
}

# Docker Desktop writes its context into ~/.kube/config (cannot be prevented). Copy it into the project kubeconfig
# and restore the global current-context if Docker Desktop changed it (CLAUDE.md 13.2).
_dd_project_kubeconfig() {
  local global="$HOME/.kube/config" before="${1:-}"
  [[ -f "$global" ]] || die "Docker Desktop did not write $global" "check Docker Desktop → Settings → Kubernetes"
  use_project_kubeconfig
  KUBECONFIG="$global" kubectl config view --raw --minify --context "$DD_CONTEXT" > "$KUBECONFIG"
  chmod 600 "$KUBECONFIG"
  if [[ -n "$before" && "$before" != "$DD_CONTEXT" ]]; then
    KUBECONFIG="$global" kubectl config use-context "$before" >/dev/null && log_ok "restored global current-context: $before"
  fi
}

_dd_label_cell() {
  local nodes cell
  nodes="$(kubectl get nodes -o name | sed 's#^node/##')"
  cell="$(cell_node "$nodes")"
  [[ -n "$cell" ]] || die "no worker node found" "set DD_NODES >= 2"
  kubectl label node "$cell" cloudfoundry.org/cell=true cloudfoundry.org/zone=z1 --overwrite >/dev/null
  kubectl taint nodes "$cell" cloudfoundry.org/cell=true:NoSchedule --overwrite >/dev/null
  log_ok "Diego cell node: $cell (label + taint)"
}

provider_preflight() {
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable" "start Docker Desktop"
  docker desktop version >/dev/null 2>&1 || die "'docker desktop' CLI not available" "update Docker Desktop (>= 4.38)"
  docker info --format '{{json .DriverStatus}}' | grep -q containerd.snapshotter \
    || die "containerd image store is not enabled" "Docker Desktop → Settings → General → 'Use containerd for pulling and storing images'"
  command -v kubectl >/dev/null || die "kubectl missing" "run: make prereqs"
}

provider_ensure() {
  local before=""
  [[ -f "$HOME/.kube/config" ]] && before="$(KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null || true)"
  _dd_enable_kubernetes
  _dd_project_kubeconfig "$before"
  kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null
  _dd_label_cell
}

provider_delete() {
  if [[ "$(_dd_status_field State)" == "running" ]]; then
    log_info "resetting the Docker Desktop Kubernetes cluster (removes Cloud Foundry; Kubernetes stays enabled)"
    docker desktop kubernetes reset-cluster >/dev/null
    log_ok "Docker Desktop Kubernetes cluster reset"
  fi
}

provider_health() {
  use_project_kubeconfig
  [[ "$(_dd_status_field State)" == "running" ]] || { log_error "Docker Desktop Kubernetes is not running"; return 1; }
  local notready
  notready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready"' | wc -l | tr -d ' ')"
  [[ "$notready" == "0" ]] || { log_error "$notready node(s) not Ready"; return 1; }
  kubectl get nodes -l cloudfoundry.org/cell=true --no-headers 2>/dev/null | grep -q . || { log_error "no node labelled cloudfoundry.org/cell=true"; return 1; }
  log_ok "Docker Desktop Kubernetes: all nodes Ready, cell node present"
}
