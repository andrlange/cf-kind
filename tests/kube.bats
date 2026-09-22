setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/kube.sh
  source "$CFKD_ROOT/scripts/kube.sh"
}

@test "use_project_kubeconfig sets KUBECONFIG to the project file, whatever the caller set" {
  export KUBECONFIG="$HOME/.kube/config"
  use_project_kubeconfig
  [ "$KUBECONFIG" = "$CFKD_HOME/kubeconfig" ]
}

@test "use_project_kubeconfig creates CFKD_HOME with 0700 and the file with 0600" {
  use_project_kubeconfig
  [ "$(stat -f %Lp "$CFKD_HOME")" = "700" ]
  [ "$(stat -f %Lp "$KUBECONFIG")" = "600" ]
}

@test "kube-env prints an eval-able export line" {
  run "$CFKD_ROOT/scripts/kube.sh" env
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "export KUBECONFIG='$CFKD_HOME/kubeconfig'" ]
  [ "${lines[1]}" = "export CF_HOME='$CFKD_HOME/cf'" ]
}

@test "kubectl wrapper never uses ~/.kube/config" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "KUBECONFIG=$KUBECONFIG ARGS=$*"\n' > "$BATS_TEST_TMPDIR/bin/kubectl"
  chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" KUBECONFIG="$HOME/.kube/config" run "$CFKD_ROOT/scripts/kube.sh" kubectl get pods -A
  [ "$output" = "KUBECONFIG=$CFKD_HOME/kubeconfig ARGS=get pods -A" ]
}

@test "global_kubeconfig_fingerprint changes only when the file changes" {
  f="$BATS_TEST_TMPDIR/cfg"
  echo a > "$f"
  a="$(global_kubeconfig_fingerprint "$f")"
  [ "$a" = "$(global_kubeconfig_fingerprint "$f")" ]
  echo b > "$f"
  [ "$a" != "$(global_kubeconfig_fingerprint "$f")" ]
  [ "$(global_kubeconfig_fingerprint "$BATS_TEST_TMPDIR/missing")" = "absent" ]
}
