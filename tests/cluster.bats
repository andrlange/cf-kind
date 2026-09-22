setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/cluster.sh
  source "$CFKD_ROOT/scripts/cluster.sh"
}

@test "load_provider loads the kind adapter" {
  load_provider kind
  [ "$(provider_kube_context)" = "kind-cfk8s" ]
}

@test "load_provider rejects unknown providers" {
  run load_provider doesnotexist
  [ "$status" -ne 0 ]
  [[ "$output" == *"doesnotexist"* ]] || false
}

@test "load_provider rejects adapters without mandatory functions" {
  mkdir -p "$BATS_TEST_TMPDIR/providers"
  echo 'provider_ensure() { :; }' > "$BATS_TEST_TMPDIR/providers/half.sh"
  PROVIDERS_DIR="$BATS_TEST_TMPDIR/providers" run load_provider half
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not implement provider_preflight"* ]] || false
}

@test "cmd_down switches the local resolver to passthrough" {
  mkdir -p "$BATS_TEST_TMPDIR/providers"
  cat > "$BATS_TEST_TMPDIR/providers/stub.sh" <<'P'
provider_preflight() { :; }
provider_ensure() { :; }
provider_delete() { echo "delete" >> "$CALLS"; }
provider_kube_context() { echo stub; }
provider_health() { :; }
P
  printf '#!/usr/bin/env bash\necho "dns $*" >> "$CALLS"\n' > "$BATS_TEST_TMPDIR/dns.sh"
  chmod +x "$BATS_TEST_TMPDIR/dns.sh"
  export CALLS="$BATS_TEST_TMPDIR/calls" PROVIDERS_DIR="$BATS_TEST_TMPDIR/providers" DNS_SCRIPT="$BATS_TEST_TMPDIR/dns.sh" K8S_PROVIDER=stub
  UPSTREAM_DIR="$BATS_TEST_TMPDIR/up" run cmd_down
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS" | tr '\n' ' ')" = "delete dns deactivate " ]
}
