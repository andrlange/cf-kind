#!/usr/bin/env bash
# Provider adapter "kind" (CLAUDE.md 4.2/4.4): upstream reference, cluster "cfk8s" from upstream/kind.yaml.
# Deviations from upstream create-kind.sh: kubeconfig project-local only, port mappings on 127.0.0.1 only.
# Loaded by scripts/cluster.sh via `source`.

# shellcheck source=../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib.sh"

KIND_CLUSTER="cfk8s"
UPSTREAM_DIR="${UPSTREAM_DIR:-$CFKD_ROOT/upstream}"

# upstream kind.yaml with listenAddress 127.0.0.1 for every hostPort line (demo not reachable from foreign Wi-Fi)
render_kind_config() {
  awk '
    { print }
    /^[[:space:]]+hostPort:/ {
      match($0, /^[[:space:]]+/)
      printf "%slistenAddress: \"127.0.0.1\"\n", substr($0, 1, RLENGTH)
    }
  ' "$1"
}

render_mirror_hosts_toml() {
  local cache="$1" remote="$2"
  cat <<EOF
server = "$remote"

[host."http://$cache:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
}

provider_kube_context() { echo "kind-$KIND_CLUSTER"; }

# Docker network "kind" with a pinned subnet (CLAUDE.md 10). kind reuses an existing network of that name.
kind_network_args() {
  local net="${KIND_SUBNET%/*}"
  echo "--driver bridge --subnet $KIND_SUBNET --gateway ${net%.*}.1 -o com.docker.network.bridge.enable_ip_masquerade=true kind"
}

_ensure_kind_network() {
  local current
  current="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    # shellcheck disable=SC2046
    docker network create $(kind_network_args) >/dev/null
    log_ok "docker network kind created with subnet $KIND_SUBNET"
  elif [[ " $current " != *" $KIND_SUBNET "* ]]; then
    log_warn "docker network kind uses $current instead of $KIND_SUBNET — takes effect after 'make nuke' (network is recreated when no cluster uses it)"
  fi
}

_kind_tools() {
  # upstream pins the versions (scripts/tools.sh), binaries end up in upstream/bin
  # shellcheck source=/dev/null
  source "$UPSTREAM_DIR/scripts/tools.sh"
  tools::install::kind
  tools::install::kubectl
}

_kind_cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"
}

_configure_mirrors() {
  local node pair cache remote registry
  for node in $(kind get nodes --name "$KIND_CLUSTER"); do
    for pair in "docker-io https://registry-1.docker.io docker.io" "ghcr-io https://ghcr.io ghcr.io" "quay-io https://quay.io quay.io"; do
      # shellcheck disable=SC2086
      set -- $pair
      cache="$1" remote="$2" registry="$3"
      docker exec "$node" mkdir -p "/etc/containerd/certs.d/$registry"
      render_mirror_hosts_toml "$cache" "$remote" | docker exec -i "$node" sh -c "cat > /etc/containerd/certs.d/$registry/hosts.toml"
    done
  done
  log_ok "registry mirrors configured on all nodes"
}

provider_preflight() {
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable" "start Docker Desktop"
  _kind_tools
  if ! _kind_cluster_exists; then
    local p
    for p in 80 443 2222; do
      if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then die "port $p is in use" "find the process: lsof -nP -iTCP:$p -sTCP:LISTEN"; fi
    done
  fi
}

provider_ensure() {
  _kind_tools
  use_project_kubeconfig
  if _kind_cluster_exists; then
    log_ok "kind cluster $KIND_CLUSTER already exists"
    kind export kubeconfig --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
  else
    _ensure_kind_network
    local cfg="$CFKD_HOME/kind.yaml"
    render_kind_config "$UPSTREAM_DIR/kind.yaml" > "$cfg"
    log_info "creating kind cluster $KIND_CLUSTER (kubeconfig: $KUBECONFIG)"
    kind create cluster --name "$KIND_CLUSTER" --config "$cfg" --kubeconfig "$KUBECONFIG"
  fi
  kubectl taint nodes -l cloudfoundry.org/cell=true cloudfoundry.org/cell=true:NoSchedule --overwrite >/dev/null

  if [[ "${DISABLE_CACHE:-false}" != "true" ]]; then
    docker compose -p cache -f "$UPSTREAM_DIR/scripts/docker-compose-registries.yaml" up -d --quiet-pull
    _configure_mirrors
  fi
  if [[ "${CF_OPTIONAL_COMPONENTS:-true}" == "true" ]]; then
    docker compose -p nfs -f "$UPSTREAM_DIR/scripts/docker-compose-nfs.yaml" up -d --quiet-pull
  fi
}

provider_delete() {
  _kind_tools
  use_project_kubeconfig
  if _kind_cluster_exists; then
    kind delete cluster --name "$KIND_CLUSTER" --kubeconfig "$KUBECONFIG"
  fi
  docker compose -p cache -f "$UPSTREAM_DIR/scripts/docker-compose-registries.yaml" down >/dev/null 2>&1 || true
  docker compose -p nfs -f "$UPSTREAM_DIR/scripts/docker-compose-nfs.yaml" down >/dev/null 2>&1 || true
  if [[ "$(docker network inspect kind --format '{{len .Containers}}' 2>/dev/null || echo x)" == "0" ]]; then
    docker network rm kind >/dev/null && log_ok "docker network kind removed (recreated with KIND_SUBNET on next up)"
  fi
  log_ok "kind cluster and helper containers removed (image caches in volumes cache_* are kept)"
}

provider_health() {
  _kind_tools >/dev/null
  use_project_kubeconfig
  _kind_cluster_exists || { log_error "kind cluster $KIND_CLUSTER does not exist"; return 1; }
  local notready
  notready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready"' | wc -l | tr -d ' ')"
  [[ "$notready" == "0" ]] || { log_error "$notready node(s) not Ready"; return 1; }
  kubectl get nodes -l cloudfoundry.org/cell=true --no-headers 2>/dev/null | grep -q . || { log_error "no node with label cloudfoundry.org/cell=true"; return 1; }
  log_ok "kind cluster $KIND_CLUSTER: all nodes Ready, cell node present"
}
