#!/usr/bin/env bash
# Pinned checkout of cloudfoundry/kind-deployment under upstream/ plus idempotent patches from patches/.
#   scripts/upstream.sh ensure          bring the checkout to the pin and apply patches
#   scripts/upstream.sh make TARGET…    run an upstream make target with the project-local environment
#   scripts/upstream.sh status          show pin and patch state
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

UPSTREAM_DIR="${UPSTREAM_DIR:-$CFKD_ROOT/upstream}"
UPSTREAM_LOCK="${UPSTREAM_LOCK:-$CFKD_ROOT/upstream.lock}"
PATCHES_DIR="${PATCHES_DIR:-$CFKD_ROOT/patches}"
PATCH_MARKER=".cfkd-patches"

read_lock() {
  sed -nE "s/^$1=(.*)$/\\1/p" "$UPSTREAM_LOCK" | head -1
}

patch_files() {
  find "$PATCHES_DIR" -maxdepth 1 -name '*.patch' 2>/dev/null | sort
}

patches_fingerprint() {
  local files; files="$(patch_files)"
  if [[ -z "$files" ]]; then echo none; return; fi
  # shellcheck disable=SC2086
  cat $files | shasum -a 256 | awk '{print $1}'
}

# apply_patches REPO — applies all patches exactly once; if the patch set changed, resets tracked files first.
apply_patches() {
  local repo="$1" want have f
  want="$(patches_fingerprint)"
  have="$(cat "$repo/$PATCH_MARKER" 2>/dev/null || true)"
  if [[ "$want" == "$have" ]]; then
    log_ok "patches already applied ($want)"
    return 0
  fi
  git -C "$repo" checkout -q -- .
  for f in $(patch_files); do
    git -C "$repo" apply --whitespace=nowarn "$f" || die "patch $(basename "$f") does not apply" "adapt the patch to the upstream pin (upstream.lock)"
    log_ok "patch applied: $(basename "$f")"
  done
  echo "$want" > "$repo/$PATCH_MARKER"
}

upstream_ensure() {
  local url commit head
  url="$(read_lock url)" commit="$(read_lock commit)"
  if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    [[ "${AIRGAP:-false}" == "true" ]] && die "upstream/ missing and AIRGAP=true" "fetch upstream while online first (make upstream) or import it from the artifact buffer"
    log_info "cloning $url"
    git clone -q "$url" "$UPSTREAM_DIR"
  fi
  head="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    log_info "checking out upstream pin ${commit:0:12} (was ${head:0:12})"
    git -C "$UPSTREAM_DIR" checkout -q -- .
    git -C "$UPSTREAM_DIR" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$UPSTREAM_DIR" fetch -q origin
    git -C "$UPSTREAM_DIR" checkout -q --detach "$commit"
    rm -f "$UPSTREAM_DIR/$PATCH_MARKER"
  fi
  apply_patches "$UPSTREAM_DIR"
  log_ok "upstream at pin ${commit:0:12}"
}

upstream_env() {
  use_project_kubeconfig
  use_project_cf_home
  export INSTALL_OPTIONAL_COMPONENTS="${CF_OPTIONAL_COMPONENTS:-true}"
  # domain values for patches/10-domain-and-tls.patch (values.yaml.gotmpl reads CF_*)
  [[ -n "${SYSTEM_DOMAIN:-}" ]] || derive_domains
  export CF_BASE_DOMAIN="$DOMAIN" CF_SYSTEM_DOMAIN="$SYSTEM_DOMAIN" CF_APPS_DOMAIN="$APPS_DOMAIN" CF_BLOBSTORE_DOMAIN="$BLOBSTORE_DOMAIN"
  if [[ "$DOMAIN" == "$NIP_DOMAIN" ]]; then
    export CF_GATEWAY_TLS_SECRET="all-in-one-tls" CF_CERT_EXTRA_SANS=""
  else
    # gorouter verifies backends against the route host (server_cert_domain_san = api.<system domain> …), and
    # upstream serves the internal all-in-one certificate there — so it must carry the demo domain names too.
    export CF_GATEWAY_TLS_SECRET="public-tls" CF_CERT_EXTRA_SANS="$CERT_SANS"
  fi
  if [[ ":$PATH:" != *":$UPSTREAM_DIR/bin:"* ]]; then export PATH="$UPSTREAM_DIR/bin:$PATH"; fi
}

# Upstream scripts assume tools that only create-kind.sh installs there (e.g. yq in upload_buildpacks.sh).
# Since the cluster comes from the provider adapter, we provide them here — in the versions of the upstream pin.
upstream_tools() {
  # shellcheck source=/dev/null
  source "$UPSTREAM_DIR/scripts/tools.sh"
  tools::install::kubectl
  tools::install::yq
  tools::install::crane
}

upstream_make() {
  upstream_env
  upstream_tools
  make -C "$UPSTREAM_DIR" "$@"
}

main() {
  load_config
  case "${1:-}" in
    ensure) upstream_ensure ;;
    make) shift; upstream_ensure; upstream_make "$@" ;;
    status)
      printf 'Pin:     %s @ %s\n' "$(read_lock url)" "$(read_lock commit)"
      printf 'HEAD:    %s\n' "$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || echo 'not checked out')"
      printf 'Patches: %s\n' "$(cat "$UPSTREAM_DIR/$PATCH_MARKER" 2>/dev/null || echo 'not applied')"
      ;;
    *) die "unknown command '${1:-}'" "usage: scripts/upstream.sh ensure|make TARGET…|status" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
