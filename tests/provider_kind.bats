setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../providers/kind.sh
  source "$CFKD_ROOT/providers/kind.sh"
  src="$BATS_TEST_TMPDIR/kind.yaml"
  cat > "$src" <<'Y'
nodes:
- role: control-plane
- role: worker
  extraPortMappings:
  - containerPort: 31080
    hostPort: 80
  - containerPort: 31443
    hostPort: 443
- role: worker
Y
}

@test "render_kind_config binds every port mapping to 127.0.0.1" {
  run render_kind_config "$src"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'listenAddress: "127.0.0.1"' <<<"$output")" -eq 2 ]
  [[ "$output" == *$'    hostPort: 80\n    listenAddress: "127.0.0.1"'* ]] || false
}

@test "render_kind_config leaves the rest unchanged" {
  run render_kind_config "$src"
  [ "$(grep -v listenAddress <<<"$output")" = "$(cat "$src")" ]
}

@test "render_kind_config works with the real upstream kind.yaml" {
  [ -f "$CFKD_ROOT/upstream/kind.yaml" ] || skip "upstream not checked out"
  run render_kind_config "$CFKD_ROOT/upstream/kind.yaml"
  [ "$(grep -c 'hostPort:' <<<"$output")" -eq "$(grep -c 'listenAddress: "127.0.0.1"' <<<"$output")" ]
}

@test "render_mirror_hosts_toml points at the cache container" {
  run render_mirror_hosts_toml ghcr-io https://ghcr.io
  [[ "$output" == *'server = "https://ghcr.io"'* ]] || false
  [[ "$output" == *'[host."http://ghcr-io:5000"]'* ]] || false
  [[ "$output" == *'capabilities = ["pull", "resolve"]'* ]] || false
}

@test "provider_kube_context is kind-cfk8s" {
  [ "$(provider_kube_context)" = "kind-cfk8s" ]
}

@test "adapter implements all mandatory functions" {
  for f in provider_preflight provider_ensure provider_delete provider_kube_context provider_health; do
    declare -F "$f" >/dev/null
  done
}

@test "provider_health provides kind/kubectl itself (no kind needed in the caller's PATH)" {
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "get clusters" ] && echo cfk8s\n' > "$BATS_TEST_TMPDIR/stub/kind"
  printf '#!/usr/bin/env bash\ncase "$*" in *cell*) echo "n2 Ready";; *) echo "n1 Ready";; esac\n' > "$BATS_TEST_TMPDIR/stub/kubectl"
  chmod +x "$BATS_TEST_TMPDIR/stub/"*
  _kind_tools() { export PATH="$BATS_TEST_TMPDIR/stub:$PATH"; }
  PATH="/usr/bin:/bin" run provider_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"all nodes Ready"* ]] || false
}

@test "kind_network_args pins the configured subnet and keeps masquerading" {
  KIND_SUBNET=10.213.0.0/16 run kind_network_args
  [ "$output" = "--driver bridge --subnet 10.213.0.0/16 --gateway 10.213.0.1 -o com.docker.network.bridge.enable_ip_masquerade=true kind" ]
}
