#!/usr/bin/env bash
# Shared functions for all cf-kind-demo scripts. Sourced via `source`, never executed directly.
# Keep Bash 3.2 compatible (macOS default bash).

CFKD_ROOT="${CFKD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFKD_HOME="${CFKD_HOME:-$HOME/.config/cf-kind-demo}"
CFKD_CONFIG="${CFKD_CONFIG:-$CFKD_ROOT/config.env}"
NIP_DOMAIN="127-0-0-1.nip.io"

# All keys allowed in config.env (order = order in config.env.example)
CONFIG_KEYS="K8S_PROVIDER TLS_MODE DNS_ZONE DOMAIN DOMAIN_LAYOUT SYS_SUBDOMAIN APP_SUBDOMAIN ACME_DNS_PROVIDER ACME_DNS_CREDENTIALS ACME_EMAIL ACME_ENV GCP_PROJECT AIRGAP CF_OPTIONAL_COMPONENTS KIND_SUBNET"

if [[ -t 2 ]]; then
  C_RED=$'\033[31m' C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_BLU=$'\033[34m' C_OFF=$'\033[0m'
else
  C_RED="" C_YEL="" C_GRN="" C_BLU="" C_OFF=""
fi

log_info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
log_ok()    { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
log_warn()  { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
log_error() { printf '%sfail%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }

# die "<what is broken>" ["<what to do>"]
die() {
  log_error "$1"
  if [[ -n "${2:-}" ]]; then printf '     -> %s\n' "$2" >&2; fi
  exit 1
}

# version_ge A B: rc 0 if version A >= B. Non-numeric suffixes (+sha, -rc1) are ignored.
version_ge() {
  local a b i x y
  a="${1%%[+ -]*}" b="${2%%[+ -]*}"
  local IFS=.
  # shellcheck disable=SC2206
  local -a av=($a) bv=($b)
  for ((i = 0; i < ${#av[@]} || i < ${#bv[@]}; i++)); do
    x="${av[i]:-0}" y="${bv[i]:-0}"
    x="${x%%[!0-9]*}" y="${y%%[!0-9]*}"
    x="${x:-0}" y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# Loads config.env.example (defaults) and config.env; environment variables already set win.
load_config() {
  local k
  # Capture overrides from the real environment only on the first call — otherwise a second call would treat
  # the values exported by ourselves as overrides and ignore changes to config.env.
  if [[ -z "${_CFKD_OVERRIDES_CAPTURED:-}" ]]; then
    _CFKD_OVERRIDES=""
    for k in $CONFIG_KEYS; do
      if [[ -n "${!k+x}" ]]; then _CFKD_OVERRIDES="$_CFKD_OVERRIDES $k"; eval "_CFKD_OVR_$k=\"\${$k}\""; fi
    done
    _CFKD_OVERRIDES_CAPTURED=1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$CFKD_ROOT/config.env.example"
  # shellcheck source=/dev/null
  if [[ -f "$CFKD_CONFIG" ]]; then source "$CFKD_CONFIG"; fi
  set +a
  for k in $_CFKD_OVERRIDES; do eval "export $k=\"\${_CFKD_OVR_$k}\""; done
  derive_domains
}

# Computes all derived domain values. The only place that knows the naming scheme (chapter 9.3).
derive_domains() {
  if [[ -z "${DOMAIN:-}" || "$DOMAIN" == "$NIP_DOMAIN" ]]; then
    DOMAIN="$NIP_DOMAIN"
    SYSTEM_DOMAIN="cf.$NIP_DOMAIN"
    APPS_DOMAIN="apps.$NIP_DOMAIN"
    BLOBSTORE_DOMAIN="blobstore.$NIP_DOMAIN"
    CERT_SANS="*.$SYSTEM_DOMAIN *.$APPS_DOMAIN *.$BLOBSTORE_DOMAIN"
  else
    case "${DOMAIN_LAYOUT:-split}" in
      split)
        SYSTEM_DOMAIN="${SYS_SUBDOMAIN:-sys}.$DOMAIN"
        APPS_DOMAIN="${APP_SUBDOMAIN:-app}.$DOMAIN"
        BLOBSTORE_DOMAIN="blobstore.$SYSTEM_DOMAIN"
        # *.<D> covers sys.<D> and app.<D> — Let's Encrypt rejects redundant names in the same request
        CERT_SANS="*.$SYSTEM_DOMAIN *.$APPS_DOMAIN *.$BLOBSTORE_DOMAIN *.$DOMAIN $DOMAIN"
        ;;
      flat)
        SYSTEM_DOMAIN="$DOMAIN"
        APPS_DOMAIN="$DOMAIN"
        BLOBSTORE_DOMAIN="blobstore.$DOMAIN"
        CERT_SANS="*.$DOMAIN $DOMAIN *.$BLOBSTORE_DOMAIN"
        ;;
      *)
        SYSTEM_DOMAIN="" APPS_DOMAIN="" BLOBSTORE_DOMAIN="" CERT_SANS=""
        ;;
    esac
  fi
  RESOLVER_DOMAINS="$DOMAIN"
  if [[ "$DOMAIN" != "$NIP_DOMAIN" ]]; then RESOLVER_DOMAINS="$DOMAIN $NIP_DOMAIN"; fi
  export DOMAIN SYSTEM_DOMAIN APPS_DOMAIN BLOBSTORE_DOMAIN CERT_SANS RESOLVER_DOMAINS
}

# Prints one line per problem found; rc 1 if there are problems.
validate_config() {
  local errors=0
  _cfg_err() { printf '%s\n' "$*"; errors=$((errors + 1)); }

  case "${K8S_PROVIDER:-}" in docker-desktop | kind | k3d) ;; *) _cfg_err "K8S_PROVIDER='${K8S_PROVIDER:-}' invalid (allowed: docker-desktop | kind | k3d)" ;; esac
  case "${TLS_MODE:-}" in selfsigned | letsencrypt) ;; *) _cfg_err "TLS_MODE='${TLS_MODE:-}' invalid (allowed: selfsigned | letsencrypt)" ;; esac
  case "${DOMAIN_LAYOUT:-}" in split | flat) ;; *) _cfg_err "DOMAIN_LAYOUT='${DOMAIN_LAYOUT:-}' invalid (allowed: split | flat)" ;; esac
  case "${AIRGAP:-}" in true | false) ;; *) _cfg_err "AIRGAP='${AIRGAP:-}' invalid (allowed: true | false)" ;; esac
  if [[ ! "${KIND_SUBNET:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([89]|1[0-9]|2[0-4])$ ]]; then _cfg_err "KIND_SUBNET='${KIND_SUBNET:-}' must be an IPv4 CIDR between /8 and /24 (e.g. 10.213.0.0/16)"; fi
  case "${CF_OPTIONAL_COMPONENTS:-}" in true | false) ;; *) _cfg_err "CF_OPTIONAL_COMPONENTS='${CF_OPTIONAL_COMPONENTS:-}' invalid (allowed: true | false)" ;; esac
  case "${ACME_ENV:-}" in staging | prod) ;; *) _cfg_err "ACME_ENV='${ACME_ENV:-}' invalid (allowed: staging | prod)" ;; esac

  local label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
  if [[ ! "$DOMAIN" =~ ^($label\.)+[a-z]{2,}$ ]]; then _cfg_err "DOMAIN='$DOMAIN' is not a valid domain name (lowercase letters, digits, '-' only)"; fi
  local sub
  for sub in "${SYS_SUBDOMAIN:-}" "${APP_SUBDOMAIN:-}"; do
    if [[ ! "$sub" =~ ^$label$ ]]; then _cfg_err "SYS_SUBDOMAIN/APP_SUBDOMAIN='$sub' must be a single DNS label"; fi
  done

  if [[ "${TLS_MODE:-}" == "letsencrypt" ]]; then
    if [[ "$DOMAIN" == "$NIP_DOMAIN" ]]; then
      _cfg_err "TLS_MODE=letsencrypt requires a custom DOMAIN (e.g. DOMAIN=kind.cfapps.cool)"
    elif [[ -z "${DNS_ZONE:-}" ]]; then
      _cfg_err "TLS_MODE=letsencrypt requires DNS_ZONE"
    elif [[ "$DOMAIN" != "$DNS_ZONE" && "$DOMAIN" != *".$DNS_ZONE" ]]; then
      _cfg_err "DOMAIN='$DOMAIN' is not inside DNS_ZONE='$DNS_ZONE'"
    fi
    if [[ "${ACME_EMAIL:-}" != *@*.* ]]; then _cfg_err "TLS_MODE=letsencrypt requires ACME_EMAIL (e.g. admin@${DNS_ZONE:-example.org})"; fi
    if [[ "${ACME_DNS_PROVIDER:-}" == "gcloud" && -z "${GCP_PROJECT:-}" ]]; then _cfg_err "TLS_MODE=letsencrypt with ACME_DNS_PROVIDER=gcloud requires GCP_PROJECT (run: make configure GCP_PROJECT=<your-gcp-project>)"; fi
    if [[ -z "${ACME_DNS_PROVIDER:-}" ]]; then _cfg_err "TLS_MODE=letsencrypt requires ACME_DNS_PROVIDER"; fi
  fi

  unset -f _cfg_err
  [[ $errors -eq 0 ]]
}

# Project-local kubeconfig (CLAUDE.md 13.2): ~/.kube/config is never read or written.
# Sets KUBECONFIG explicitly, independent of the caller's environment.
use_project_kubeconfig() {
  mkdir -p "$CFKD_HOME"
  chmod 700 "$CFKD_HOME"
  KUBECONFIG="$CFKD_HOME/kubeconfig"
  [[ -f "$KUBECONFIG" ]] || : > "$KUBECONFIG"
  chmod 600 "$KUBECONFIG"
  export KUBECONFIG
}

# Fingerprint of the global kubeconfig so tests/doctor can verify we do not modify it.
global_kubeconfig_fingerprint() {
  local f="${1:-$HOME/.kube/config}"
  if [[ -f "$f" ]]; then shasum -a 256 "$f" | awk '{print $1}'; else echo absent; fi
}

# Project-local cf CLI home: ~/.cf/config.json of other CF targets stays untouched (same principle as 13.2).
use_project_cf_home() {
  mkdir -p "$CFKD_HOME/cf"
  chmod 700 "$CFKD_HOME" "$CFKD_HOME/cf"
  CF_HOME="$CFKD_HOME/cf"
  export CF_HOME
}
