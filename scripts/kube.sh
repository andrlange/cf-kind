#!/usr/bin/env bash
# Transparent access to the demo cluster via the project-local kubeconfig (CLAUDE.md 13.2).
#   scripts/kube.sh env                 export line for: eval "$(make -s kube-env)"
#   scripts/kube.sh kubectl|helm|k9s …  run the tool with the project kubeconfig
#   scripts/kube.sh shell               subshell with KUBECONFIG set
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

main() {
  use_project_kubeconfig
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    env) use_project_cf_home; printf "export KUBECONFIG='%s'\nexport CF_HOME='%s'\n" "$KUBECONFIG" "$CF_HOME" ;;
    kubectl | helm | k9s)
      command -v "$cmd" >/dev/null || die "$cmd not found" "run: make prereqs"
      exec "$cmd" "$@"
      ;;
    shell)
      use_project_cf_home
      log_info "subshell with KUBECONFIG=$KUBECONFIG and CF_HOME=$CF_HOME — kubectl/helm/k9s/cf point at the demo. Leave with 'exit'."
      CFKD_SHELL=1 exec "${SHELL:-/bin/bash}" -i
      ;;
    *) die "unknown command '$cmd'" "usage: scripts/kube.sh env|kubectl|helm|k9s|shell" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
