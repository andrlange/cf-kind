#!/usr/bin/env bash
# Checks whether this Mac meets all prerequisites and installs missing tools via `brew bundle`.
#   scripts/prereqs.sh          check + install
#   scripts/prereqs.sh --check  check only (automatic with AIRGAP=true)
# Exit code != 0 if at least one check ends with "fail". Docker Desktop settings are only read.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MIN_DOCKER_DESKTOP="4.38"
MIN_MEM_GIB=8
REC_MEM_GIB=16
REC_CPUS=6
MIN_DISK_GIB=40
REQUIRED_PORTS="80 443 2222"
TCP_ROUTER_PORTS="$(seq -s ' ' 32000 32019)"

N_OK=0 N_WARN=0 N_FAIL=0

# check ok|warn|fail "<message>" ["<what to do>"]
check() {
  case "$1" in
    ok) log_ok "$2"; N_OK=$((N_OK + 1)) ;;
    warn) log_warn "$2"; N_WARN=$((N_WARN + 1)) ;;
    fail) log_error "$2"; N_FAIL=$((N_FAIL + 1)) ;;
  esac
  if [[ "$1" != ok && -n "${3:-}" ]]; then printf '     -> %s\n' "$3" >&2; fi
  return 0
}


port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

parse_docker_desktop_version() {
  sed -nE 's/^Docker Desktop ([0-9]+(\.[0-9]+)+).*/\1/p' | head -1
}

bytes_to_gib() {
  echo $(($1 / 1073741824))
}

check_platform() {
  if [[ "$(uname -m)" == "arm64" ]]; then check ok "Apple Silicon (arm64), macOS $(sw_vers -productVersion)"
  else check fail "architecture $(uname -m) is not supported" "cf-kind-demo runs on Apple Silicon only"; fi
}

# reads `brew bundle check --verbose` from stdin and prints the missing formulae/casks
missing_brew_formulae() {
  sed -nE 's/^→ (Formula|Cask) ([^ ]+) needs to be installed.*/\2/p' | tr '\n' ' ' | sed 's/ $//'
}

# formulae from third-party taps that Homebrew ≥ 7 must trust explicitly
TRUSTED_TAP_FORMULAE="cloudfoundry/tap/cf-cli@8"

check_brew() {
  if ! command -v brew >/dev/null; then
    check fail "Homebrew missing" "install it: https://brew.sh"
    return 0
  fi
  check ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

  local report missing
  report="$(brew bundle check --file="$CFKD_ROOT/Brewfile" --verbose --no-upgrade 2>&1 || true)"
  missing="$(missing_brew_formulae <<<"$report")"
  if [[ -z "$missing" ]]; then
    check ok "all tools from the Brewfile installed"
  elif [[ "$MODE" == check ]]; then
    check fail "missing tools: $missing" "run: make prereqs (without --check) to install them"
  else
    log_info "installing missing tools: $missing"
    if brew trust --help >/dev/null 2>&1; then
      log_info "trusting the official Cloud Foundry tap: brew trust --formula $TRUSTED_TAP_FORMULAE"
      # shellcheck disable=SC2086
      brew trust --formula $TRUSTED_TAP_FORMULAE >/dev/null 2>&1 || true
    fi
    if brew bundle install --file="$CFKD_ROOT/Brewfile" --no-upgrade; then check ok "tools from the Brewfile installed: $missing"
    else check fail "brew bundle install failed" "check the output above, then rerun: make prereqs"; fi
  fi
}

check_docker() {
  if ! command -v docker >/dev/null; then
    check fail "docker CLI missing" "install Docker Desktop (make prereqs) and start it"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    check fail "Docker daemon not reachable" "start Docker Desktop: open -a Docker (or docker desktop start)"
    return 1
  fi
  local ctx; ctx="$(docker context show 2>/dev/null || true)"
  if [[ "$ctx" == "desktop-linux" ]]; then check ok "Docker context desktop-linux"
  else check warn "Docker context is '$ctx'" "run: docker context use desktop-linux (e.g. when Podman Desktop is installed alongside)"; fi

  local ver
  ver="$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null | parse_docker_desktop_version)"
  if [[ -z "$ver" ]]; then
    check warn "Docker is running, but not Docker Desktop (untested)" "use Docker Desktop (docs/PREREQUISITES.md)"
  elif version_ge "$ver" "$MIN_DOCKER_DESKTOP"; then
    check ok "Docker Desktop $ver"
  else
    check warn "Docker Desktop $ver is older than $MIN_DOCKER_DESKTOP" "update Docker Desktop (docker desktop update)"
  fi

  local mem cpus
  mem="$(bytes_to_gib "$(docker info --format '{{.MemTotal}}')")"
  cpus="$(docker info --format '{{.NCPU}}')"
  if ((mem < MIN_MEM_GIB)); then check fail "Docker memory ${mem} GiB < ${MIN_MEM_GIB} GiB" "increase Docker Desktop → Settings → Resources → Memory"
  elif ((mem < REC_MEM_GIB)); then check warn "Docker memory ${mem} GiB (recommended ≥ ${REC_MEM_GIB} GiB with services)" "Docker Desktop → Settings → Resources → Memory"
  else check ok "Docker memory ${mem} GiB"; fi
  if ((cpus < REC_CPUS)); then check warn "Docker CPUs ${cpus} (recommended ≥ ${REC_CPUS})" "Docker Desktop → Settings → Resources → CPUs"
  else check ok "Docker CPUs ${cpus}"; fi

  return 0
}

check_rosetta() {
  local arch
  if [[ "${AIRGAP:-false}" == "true" ]] && ! docker image inspect alpine:3 >/dev/null 2>&1; then
    check warn "Rosetta test skipped (airgapped, alpine:3 not available locally)"
    return
  fi
  arch="$(docker run --rm --platform linux/amd64 alpine:3 uname -m 2>/dev/null || true)"
  if [[ "$arch" == "x86_64" ]]; then check ok "amd64 emulation (Rosetta/binfmt) works"
  else check fail "amd64 containers do not run (buildpack dependencies need them, chapter 5)" "Docker Desktop → Settings → General → 'Use Rosetta for x86_64/amd64 emulation'"; fi
}

check_disk() {
  local free; free="$(df -g / | awk 'NR==2 {print $4}')"
  if ((free < MIN_DISK_GIB)); then check warn "only ${free} GB free on / (recommended ≥ ${MIN_DISK_GIB} GB)" "free up space (images, artifact buffer)"
  else check ok "${free} GB free on /"; fi
}

check_ports() {
  local p busy=""
  for p in $REQUIRED_PORTS; do port_in_use "$p" && busy="$busy $p"; done
  if [[ -n "$busy" ]]; then check fail "ports in use:$busy" "lsof -nP -iTCP:<port> -sTCP:LISTEN shows the process; stop it or reconfigure"
  else check ok "ports $REQUIRED_PORTS free"; fi
  busy=""
  for p in $TCP_ROUTER_PORTS; do port_in_use "$p" && busy="$busy $p"; done
  if [[ -n "$busy" ]]; then check warn "TCP router ports in use:$busy" "TCP routing may not be usable in the demo"
  else check ok "TCP router ports 32000–32019 free"; fi
}

check_cf_cli() {
  if ! command -v cf >/dev/null; then check fail "cf CLI missing" "run: make prereqs (installs cf-cli@8)"; return; fi
  local v; v="$(cf version | awk '{print $3}')"
  if version_ge "$v" 8; then check ok "cf CLI $v"; else check fail "cf CLI $v is too old (≥ 8)" "run: brew install cloudfoundry/tap/cf-cli@8"; fi
}

# hooks_enabled REPO — secret-scanning git hooks (.githooks) active? (CLAUDE.md 13.3)
hooks_enabled() {
  [[ "$(git -C "$1" config --get core.hooksPath 2>/dev/null || true)" == ".githooks" ]]
}

check_git_hooks() {
  if ! git -C "$CFKD_ROOT" rev-parse --git-dir >/dev/null 2>&1; then return 0; fi
  if hooks_enabled "$CFKD_ROOT"; then check ok "secret-scanning git hooks active (.githooks)"
  else check fail "secret-scanning git hooks not active" "run: make hooks"; fi
}

check_config() {
  local problems
  if problems="$(validate_config)"; then
    check ok "configuration valid (provider $K8S_PROVIDER, TLS $TLS_MODE, system domain $SYSTEM_DOMAIN)"
  else
    while IFS= read -r line; do check fail "configuration: $line" "run: make configure KEY=VALUE"; done <<<"$problems"
  fi
  if [[ "$TLS_MODE" == "letsencrypt" ]]; then
    if "$CFKD_ROOT/scripts/secrets.sh" check-dns >/dev/null 2>&1; then check ok "DNS credentials for Let's Encrypt present"
    else check warn "DNS credentials for Let's Encrypt missing (required from make certs on)" "run: make secrets-set-dns FILE=<service-account.json>"; fi
    if command -v gcloud >/dev/null; then check ok "gcloud present (for make dns-public)"
    else check warn "gcloud missing (only required for make dns-public)" "run: brew install --cask gcloud-cli"; fi
  fi
}

main() {
  MODE=install
  if [[ "${1:-}" == "--check" ]]; then MODE=check; fi
  load_config
  if [[ "$AIRGAP" == "true" ]]; then MODE=check; fi

  log_info "checking prerequisites (mode: $MODE, provider: $K8S_PROVIDER)"
  check_platform
  check_brew
  if check_docker; then check_rosetta; fi
  check_disk
  check_ports
  check_cf_cli
  check_git_hooks
  check_config

  printf '\n%d ok, %d warn, %d fail\n' "$N_OK" "$N_WARN" "$N_FAIL" >&2
  if ((N_FAIL > 0)); then die "prerequisites not met" "work through the hints above, then rerun: make prereqs"; fi
  log_ok "prerequisites met"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
