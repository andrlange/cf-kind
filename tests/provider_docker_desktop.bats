setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../providers/docker-desktop.sh
  source "$CFKD_ROOT/providers/docker-desktop.sh"
  settings="$BATS_TEST_TMPDIR/settings-store.json"
  echo '{"MemoryMiB":32768,"UseContainerdSnapshotter":true,"AutoStart":false}' > "$settings"
}

@test "render_dd_settings enables Kubernetes in kind mode with the requested nodes and keeps all other settings" {
  run render_dd_settings "$settings" 3 1.36.1
  [ "$status" -eq 0 ]
  [ "$(jq -r .KubernetesEnabled <<<"$output")" = "true" ]
  [ "$(jq -r .KubernetesMode <<<"$output")" = "kind" ]
  [ "$(jq -r .KubernetesNodesCount <<<"$output")" = "3" ]
  [ "$(jq -r .KubernetesNodesVersion <<<"$output")" = "1.36.1" ]
  [ "$(jq -r .MemoryMiB <<<"$output")" = "32768" ]
  [ "$(jq -r .AutoStart <<<"$output")" = "false" ]
}

@test "dd_k8s_matches detects whether the settings already match" {
  ! dd_k8s_matches "$settings" 3 1.36.1
  render_dd_settings "$settings" 3 1.36.1 > "$settings.new" && mv "$settings.new" "$settings"
  dd_k8s_matches "$settings" 3 1.36.1
  ! dd_k8s_matches "$settings" 4 1.36.1
}

@test "cell_node picks the last worker, like upstream's kind.yaml" {
  run cell_node $'desktop-control-plane\ndesktop-worker\ndesktop-worker2'
  [ "$output" = "desktop-worker2" ]
}

@test "provider_kube_context is docker-desktop and all adapter functions exist" {
  [ "$(provider_kube_context)" = "docker-desktop" ]
  for f in provider_preflight provider_ensure provider_delete provider_kube_context provider_health; do declare -F "$f" >/dev/null; done
}
