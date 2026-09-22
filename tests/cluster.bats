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
