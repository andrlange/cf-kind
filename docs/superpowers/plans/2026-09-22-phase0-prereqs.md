# Phase 0 — Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With `make prereqs`, `make configure`, `make secrets-set-dns` and `make dns`, a fresh Apple Silicon Mac reaches a state in which all later phases (cluster, TLS, airgap, services) can start.

**Architecture:** Thin `Makefile` as the only user interface; logic in small Bash scripts under `scripts/` (one script per responsibility, shared functions in `scripts/lib.sh`). Configuration in `config.env` (local, gitignored) on top of defaults from `config.env.example`; derived values (system/apps domain, SANs, resolver domains) are computed exclusively by `derive_domains`. Local DNS via a **user-level** dnsmasq (launchd agent, port 53535) plus `/etc/resolver/<domain>` (the only `sudo` step).

**Tech Stack:** Bash 3.2 (macOS default, no Bash 4 features), Homebrew Bundle, bats-core, shellcheck, dnsmasq, launchd, macOS Keychain (`security`).

**Spec:** `CLAUDE.md` chapter 3 (Prerequisites), 9.2 (pre-task domain), 10 (local resolver), 13 (conventions).

## Global Constraints
- Apple Silicon only (`uname -m` = `arm64`).
- Bash scripts: `set -euo pipefail`, shellcheck-clean, **Bash 3.2 compatible** (no associative arrays, no `${x,,}`, no `mapfile`, empty arrays with `${a[@]+"${a[@]}"}`).
- All scripts idempotent; every error ends with a concrete instruction for action (`die "<error>" "<what to do>"`).
- No secrets in the repo; credentials only in the Keychain or under `~/.config/cf-kind-demo/` (`0700`/`0600`).
- `sudo` exclusively in `scripts/dns.sh` for `/etc/resolver/*`, announced beforehand; never touch foreign resolver files (marker `# managed by cf-kind-demo`).
- Docker Desktop settings are **only read** in phase 0, never changed.
- Defaults: `K8S_PROVIDER=docker-desktop`, `TLS_MODE=selfsigned`, `DNS_ZONE=cfapps.cool`, `DOMAIN_LAYOUT=split`, `SYS_SUBDOMAIN=sys`, `APP_SUBDOMAIN=app`, `ACME_DNS_PROVIDER=gcloud`, `ACME_ENV=staging`, `GCP_PROJECT=<gcp-project>`.
- Minimum values: Docker Desktop ≥ 4.38, Docker memory ≥ 8 GiB (warning < 16 GiB), CPUs ≥ 6 (warning), cf CLI ≥ 8.

## File Structure
| File | Responsibility |
|---|---|
| `Brewfile` | all tools installable via brew |
| `.gitignore` | local/generated files |
| `config.env.example` | documented defaults (committed) |
| `Makefile` | user interface, no logic |
| `scripts/lib.sh` | logging, `die`, `version_ge`, load/validate config, `derive_domains` |
| `scripts/configure.sh` | write `config.env` (KEY=VALUE or interactive), `--show` |
| `scripts/prereqs.sh` | checks + `brew bundle` |
| `scripts/dns.sh` | dnsmasq agent + `/etc/resolver` setup/check/remove |
| `scripts/secrets.sh` | set/check/read GCP DNS key in the Keychain |
| `tests/*.bats` | unit tests of the pure functions |

---

### Task 1: Skeleton, test harness and `lib.sh`

**Files:**
- Create: `Brewfile`, `.gitignore`, `config.env.example`, `Makefile`, `scripts/lib.sh`, `tests/lib.bats`

**Interfaces:**
- Produces: `log_info/log_ok/log_warn/log_error msg`, `die msg [hint]`, `version_ge A B` (rc 0/1), `load_config` (sets all keys + derived values as exported variables), `derive_domains` (sets `DOMAIN SYSTEM_DOMAIN APPS_DOMAIN BLOBSTORE_DOMAIN CERT_SANS RESOLVER_DOMAINS`), `validate_config` (prints one error per line, rc≠0 on errors), variables `CFKD_ROOT CFKD_HOME CFKD_CONFIG NIP_DOMAIN CONFIG_KEYS`.

- [ ] **Step 1: Create Brewfile, .gitignore, config.env.example** (content see repository files; `cask "docker-desktop"` only `unless File.exist?("/Applications/Docker.app")`, `k3d` only with `CFKD_WITH_K3D=1`).
- [ ] **Step 2: Write failing tests** — `tests/lib.bats`:

```bash
setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/lib.sh
  source "$CFKD_ROOT/scripts/lib.sh"
}
@test "version_ge compares numerically" {
  version_ge 4.91.0 4.38; version_ge 4.38 4.38; ! version_ge 4.9 4.38; version_ge 8.18.0+fad4bcb 8
}
@test "without DOMAIN the upstream scheme with nip.io applies" {
  load_config
  [ "$DOMAIN" = "127-0-0-1.nip.io" ]; [ "$SYSTEM_DOMAIN" = "cf.127-0-0-1.nip.io" ]
  [ "$APPS_DOMAIN" = "apps.127-0-0-1.nip.io" ]; [ "$RESOLVER_DOMAINS" = "127-0-0-1.nip.io" ]
}
@test "split layout derives sys/app" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"; load_config
  [ "$SYSTEM_DOMAIN" = "sys.kind.cfapps.cool" ]; [ "$APPS_DOMAIN" = "app.kind.cfapps.cool" ]
  [ "$BLOBSTORE_DOMAIN" = "blobstore.sys.kind.cfapps.cool" ]
  [ "$CERT_SANS" = "*.sys.kind.cfapps.cool sys.kind.cfapps.cool *.app.kind.cfapps.cool app.kind.cfapps.cool *.blobstore.sys.kind.cfapps.cool *.kind.cfapps.cool kind.cfapps.cool" ]
  [ "$RESOLVER_DOMAINS" = "kind.cfapps.cool 127-0-0-1.nip.io" ]
}
@test "flat layout uses the base for system and apps" {
  printf 'DOMAIN="kind.cfapps.cool"\nDOMAIN_LAYOUT="flat"\n' > "$CFKD_CONFIG"; load_config
  [ "$SYSTEM_DOMAIN" = "kind.cfapps.cool" ]; [ "$APPS_DOMAIN" = "kind.cfapps.cool" ]
  [ "$CERT_SANS" = "*.kind.cfapps.cool kind.cfapps.cool *.blobstore.kind.cfapps.cool" ]
}
@test "environment variables override config.env" {
  echo 'ACME_ENV="staging"' > "$CFKD_CONFIG"; ACME_ENV=prod load_config; [ "$ACME_ENV" = "prod" ]
}
@test "validate_config: letsencrypt requires domain inside the zone" {
  printf 'TLS_MODE="letsencrypt"\nDOMAIN="kind.example.org"\n' > "$CFKD_CONFIG"; load_config
  run validate_config; [ "$status" -ne 0 ]; [[ "$output" == *"is not in DNS_ZONE"* ]]
}
@test "validate_config: valid letsencrypt configuration" {
  printf 'TLS_MODE="letsencrypt"\nDOMAIN="kind.cfapps.cool"\nACME_EMAIL="admin@cfapps.cool"\n' > "$CFKD_CONFIG"; load_config
  run validate_config; [ "$status" -eq 0 ]
}
@test "validate_config: unknown provider" {
  echo 'K8S_PROVIDER="minikube"' > "$CFKD_CONFIG"; load_config
  run validate_config; [ "$status" -ne 0 ]; [[ "$output" == *"K8S_PROVIDER"* ]]
}
```
- [ ] **Step 3: `brew install bats-core` and run tests** — `bats tests/lib.bats` → FAIL (`scripts/lib.sh` missing).
- [ ] **Step 4: Implement `scripts/lib.sh`** (full code in the repository; core logic):

```bash
derive_domains() {
  if [[ -z "${DOMAIN:-}" || "$DOMAIN" == "$NIP_DOMAIN" ]]; then
    DOMAIN="$NIP_DOMAIN"; SYSTEM_DOMAIN="cf.$NIP_DOMAIN"; APPS_DOMAIN="apps.$NIP_DOMAIN"; BLOBSTORE_DOMAIN="blobstore.$NIP_DOMAIN"
    CERT_SANS="*.$SYSTEM_DOMAIN *.$APPS_DOMAIN *.$BLOBSTORE_DOMAIN"
  else
    case "${DOMAIN_LAYOUT:-split}" in
      split) SYSTEM_DOMAIN="${SYS_SUBDOMAIN:-sys}.$DOMAIN"; APPS_DOMAIN="${APP_SUBDOMAIN:-app}.$DOMAIN"
             BLOBSTORE_DOMAIN="blobstore.$SYSTEM_DOMAIN"
             CERT_SANS="*.$SYSTEM_DOMAIN $SYSTEM_DOMAIN *.$APPS_DOMAIN $APPS_DOMAIN *.$BLOBSTORE_DOMAIN *.$DOMAIN $DOMAIN" ;;
      flat)  SYSTEM_DOMAIN="$DOMAIN"; APPS_DOMAIN="$DOMAIN"; BLOBSTORE_DOMAIN="blobstore.$DOMAIN"
             CERT_SANS="*.$DOMAIN $DOMAIN *.$BLOBSTORE_DOMAIN" ;;
      *) SYSTEM_DOMAIN=""; APPS_DOMAIN=""; BLOBSTORE_DOMAIN=""; CERT_SANS="" ;;
    esac
  fi
  RESOLVER_DOMAINS="$DOMAIN"; [[ "$DOMAIN" != "$NIP_DOMAIN" ]] && RESOLVER_DOMAINS="$DOMAIN $NIP_DOMAIN"
  export DOMAIN SYSTEM_DOMAIN APPS_DOMAIN BLOBSTORE_DOMAIN CERT_SANS RESOLVER_DOMAINS
}
```
- [ ] **Step 5: Tests green** — `bats tests/lib.bats` → all PASS; `shellcheck scripts/lib.sh` → no findings.
- [ ] **Step 6: Commit** (after approval by the user) — `git add Brewfile .gitignore config.env.example Makefile scripts/lib.sh tests/lib.bats && git commit -m "feat: project skeleton, config model and test harness"`

### Task 2: `make configure` / `make config-show`

**Files:**
- Create: `scripts/configure.sh`, `tests/configure.bats`
- Modify: `Makefile` (targets `configure`, `config-show`)

**Interfaces:**
- Consumes: `load_config`, `validate_config`, `CONFIG_KEYS`, `die`.
- Produces: `set_config_value FILE KEY VALUE` (replaces/appends `KEY="VALUE"`), CLI `scripts/configure.sh [KEY=VALUE ...] | --show`. Without arguments on a TTY: interactive prompt for `TLS_MODE`, `DOMAIN`, `DOMAIN_LAYOUT`, `K8S_PROVIDER`.

- [ ] **Step 1: Failing tests** — `tests/configure.bats`:

```bash
setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  source "$CFKD_ROOT/scripts/configure.sh"
}
@test "set_config_value replaces and appends" {
  printf 'A="1"\nB="2"\n' > "$CFKD_CONFIG"
  set_config_value "$CFKD_CONFIG" B 3; set_config_value "$CFKD_CONFIG" C 4
  [ "$(cat "$CFKD_CONFIG")" = $'A="1"\nB="3"\nC="4"' ]
}
@test "configure writes valid values" {
  run "$CFKD_ROOT/scripts/configure.sh" TLS_MODE=letsencrypt DOMAIN=kind.cfapps.cool ACME_EMAIL=admin@cfapps.cool
  [ "$status" -eq 0 ]; grep -q '^DOMAIN="kind.cfapps.cool"$' "$CFKD_CONFIG"
}
@test "configure rejects invalid values and leaves the file unchanged" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  run "$CFKD_ROOT/scripts/configure.sh" DOMAIN_LAYOUT=diagonal
  [ "$status" -ne 0 ]; [ "$(cat "$CFKD_CONFIG")" = 'DOMAIN="kind.cfapps.cool"' ]
}
@test "configure rejects unknown keys and special characters" {
  run "$CFKD_ROOT/scripts/configure.sh" FOO=bar; [ "$status" -ne 0 ]
  run "$CFKD_ROOT/scripts/configure.sh" 'DOMAIN=a$(id)'; [ "$status" -ne 0 ]
}
@test "--show shows derived domains" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  run "$CFKD_ROOT/scripts/configure.sh" --show
  [[ "$output" == *"SYSTEM_DOMAIN"*"sys.kind.cfapps.cool"* ]]
}
```
- [ ] **Step 2: Run tests** → FAIL (script missing).
- [ ] **Step 3: Implement `scripts/configure.sh`** (backup → set values → in a subshell `load_config && validate_config` → on error restore backup and `die`).
- [ ] **Step 4: Tests green + shellcheck.**
- [ ] **Step 5: Makefile targets** — `configure` passes only variables with `$(origin) = command line`:
  `CONFIG_ARGS := $(foreach k,$(CONFIG_KEYS),$(if $(filter command line,$(origin $(k))),$(k)=$($(k))))`
- [ ] **Step 6: Manual** — `make configure TLS_MODE=letsencrypt DOMAIN=kind.cfapps.cool ACME_EMAIL=admin@cfapps.cool && make config-show`.
- [ ] **Step 7: Commit** (after approval) — `feat: configure pre-task for domain and TLS mode`

### Task 3: `make prereqs` / `make prereqs-check`

**Files:**
- Create: `scripts/prereqs.sh`, `tests/prereqs.bats`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `load_config`, `validate_config`, `version_ge`, logging.
- Produces: `port_in_use PORT` (rc 0 = in use), `docker_desktop_version` (stdout, e.g. `4.91.0`), CLI `scripts/prereqs.sh [--check]`; exit code ≠ 0 if a `fail` check occurs. Summary `N ok, N warn, N fail`.

Checks (in order; `fail` does not abort, but is counted):
1. `uname -m` = arm64 (fail) · 2. Homebrew present (fail) · 3. `brew bundle check` → otherwise `brew bundle install` (with `--check` or `AIRGAP=true` only report) · 4. Docker daemon reachable (fail, hint `open -a Docker`) · 5. Docker context `desktop-linux` (warn) · 6. Docker Desktop version ≥ 4.38 (fail with `K8S_PROVIDER=docker-desktop`, otherwise warn) · 7. Docker memory ≥ 8 GiB (fail) / ≥ 16 GiB (warn) · 8. CPUs ≥ 6 (warn) · 9. containerd image store (`docker info` storage driver/`driver-type` contains `containerd` or `UseContainerdSnapshotter=true`; fail with `docker-desktop`) · 10. Rosetta/binfmt: `docker run --rm --platform linux/amd64 alpine:3 uname -m` = `x86_64` (fail, hint Docker Desktop → General → Rosetta) · 11. Host disk free ≥ 40 GB (warn) · 12. Ports 80/443/2222 free (fail), 32000–32019 (warn) · 13. cf CLI ≥ 8 (fail) · 14. `config.env` valid (fail) · 15. with `TLS_MODE=letsencrypt`: DNS credentials present (`scripts/secrets.sh check-dns`, warn) · 16. `gcloud` present (warn, only for `dns-public`).

- [ ] **Step 1: Failing tests** — `tests/prereqs.bats` (pure functions only):

```bash
setup() { export CFKD_ROOT="$BATS_TEST_DIRNAME/.."; source "$CFKD_ROOT/scripts/prereqs.sh"; }
@test "port_in_use detects a port in use" {
  python3 -c 'import socket,time;s=socket.socket();s.bind(("127.0.0.1",38765));s.listen();time.sleep(5)' & pid=$!; sleep 0.5
  port_in_use 38765; kill $pid
}
@test "port_in_use reports a free port" { ! port_in_use 38766; }
@test "docker_desktop_version parses the version line" {
  docker_desktop_version_from() { echo "Docker Desktop 4.91.0 (239619)" | parse_docker_desktop_version; }
  [ "$(docker_desktop_version_from)" = "4.91.0" ]
}
```
- [ ] **Step 2: Run tests** → FAIL.
- [ ] **Step 3: Implement `scripts/prereqs.sh`.**
- [ ] **Step 4: Tests green + shellcheck.**
- [ ] **Step 5: Manual** — `make prereqs` on this Mac: installs missing tools (dnsmasq, lego, mkcert, bats-core), result without `fail`.
- [ ] **Step 6: Commit** (after approval) — `feat: prereqs check and brew bundle install`

### Task 4: Local resolver `make dns` / `dns-check` / `dns-remove`

**Files:**
- Create: `scripts/dns.sh`, `tests/dns.bats`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `load_config` (`RESOLVER_DOMAINS`, `SYSTEM_DOMAIN`), `CFKD_HOME`.
- Produces: `render_dnsmasq_conf DOMAIN...`, `render_resolver`, `render_launchd_plist DNSMASQ_BIN CONF`, constants `DNS_PORT=53535`, `DNS_LABEL=io.cf-kind-demo.dnsmasq`, `RESOLVER_MARKER="# managed by cf-kind-demo"`; CLI `scripts/dns.sh setup|check|remove`.

`setup` flow: load config → write `$CFKD_HOME/dnsmasq.conf` → write `~/Library/LaunchAgents/io.cf-kind-demo.dnsmasq.plist` → `launchctl bootout` (ignore) + `launchctl bootstrap gui/$UID` → check via `dig @127.0.0.1 -p 53535` → for each resolver domain: foreign file present → `die`; content identical → skip; otherwise announce and `sudo install -m 0644` → `dscacheutil -flushcache` (sudo) → `check`.
`check`: agent running (`launchctl print`), dnsmasq answers, `dscacheutil -q host -a name probe.<domain>` returns `127.0.0.1` per resolver domain, and `api.$SYSTEM_DOMAIN` resolves.
`remove`: unload agent, delete plist/conf, only resolver files with marker via `sudo rm`.

- [ ] **Step 1: Failing tests** — `tests/dns.bats`:

```bash
setup() { export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_HOME="$BATS_TEST_TMPDIR/home"; source "$CFKD_ROOT/scripts/dns.sh"; }
@test "dnsmasq.conf contains port, loopback and one address line per domain" {
  run render_dnsmasq_conf kind.cfapps.cool 127-0-0-1.nip.io
  [[ "$output" == *"port=53535"* ]]; [[ "$output" == *"listen-address=127.0.0.1"* ]]
  [[ "$output" == *"address=/kind.cfapps.cool/127.0.0.1"* ]]; [[ "$output" == *"address=/127-0-0-1.nip.io/127.0.0.1"* ]]
  [[ "$output" == *"no-resolv"* ]]
}
@test "resolver file carries marker, nameserver and port" {
  run render_resolver
  [ "${lines[0]}" = "# managed by cf-kind-demo" ]; [[ "$output" == *"nameserver 127.0.0.1"* ]]; [[ "$output" == *"port 53535"* ]]
}
@test "launchd plist starts dnsmasq in the foreground with our config" {
  run render_launchd_plist /opt/homebrew/sbin/dnsmasq /tmp/x.conf
  [[ "$output" == *"<string>io.cf-kind-demo.dnsmasq</string>"* ]]; [[ "$output" == *"--keep-in-foreground"* ]]
  [[ "$output" == *"--conf-file=/tmp/x.conf"* ]]; plutil -lint - <<<"$output"
}
@test "is_managed_resolver distinguishes own and foreign files" {
  f="$BATS_TEST_TMPDIR/r"; render_resolver > "$f"; is_managed_resolver "$f"
  echo "nameserver 10.0.0.1" > "$f"; ! is_managed_resolver "$f"
}
```
- [ ] **Step 2: Run tests** → FAIL.
- [ ] **Step 3: Implement `scripts/dns.sh`.**
- [ ] **Step 4: Tests green + shellcheck.**
- [ ] **Step 5: Manual (user, because of sudo password)** — `! make dns`, then `make dns-check`: `api.sys.kind.cfapps.cool` → 127.0.0.1, also with Wi-Fi off.
- [ ] **Step 6: Commit** (after approval) — `feat: local dnsmasq resolver for demo domains`

### Task 5: GCP DNS credentials `make secrets-set-dns` / `secrets-check`

**Files:**
- Create: `scripts/secrets.sh`, `tests/secrets.bats`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `load_config` (`ACME_DNS_CREDENTIALS`, `GCP_PROJECT`).
- Produces: `validate_sa_json FILE` (rc 0 if `type=service_account`, `client_email`, `private_key`, `project_id` present), `dns_credentials_source` (stdout `keychain:<service>` or file path), `get_dns_credentials` (JSON on stdout — only for phase 3 scripts, never log); CLI `scripts/secrets.sh set-dns FILE [--delete-source] | check-dns`.

Store without secret in `argv`: `printf 'add-generic-password -U -a "%s" -s "%s" -l "%s" -X %s\n' "$USER" "$svc" "cf-kind-demo GCP DNS" "$(xxd -p "$file" | tr -d '\n')" | security -i`.

- [ ] **Step 1: Failing tests** — `tests/secrets.bats`:

```bash
setup() { export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env"; source "$CFKD_ROOT/scripts/secrets.sh"; }
@test "validate_sa_json accepts service account JSON" {
  f="$BATS_TEST_TMPDIR/sa.json"
  echo '{"type":"service_account","project_id":"p","client_email":"a@p.iam.gserviceaccount.com","private_key":"x"}' > "$f"
  validate_sa_json "$f"
}
@test "validate_sa_json rejects other JSON" {
  f="$BATS_TEST_TMPDIR/x.json"; echo '{"type":"authorized_user"}' > "$f"; ! validate_sa_json "$f"
  echo 'not json' > "$f"; ! validate_sa_json "$f"
}
@test "dns_credentials_source recognizes keychain and file variants" {
  ACME_DNS_CREDENTIALS="keychain:foo" run dns_credentials_source; [ "$output" = "keychain:foo" ]
  ACME_DNS_CREDENTIALS="~/x.json" run dns_credentials_source; [ "$output" = "$HOME/x.json" ]
}
```
- [ ] **Step 2: Run tests** → FAIL.
- [ ] **Step 3: Implement `scripts/secrets.sh`.**
- [ ] **Step 4: Tests green + shellcheck.**
- [ ] **Step 5: Manual (user)** — `gcloud iam service-accounts keys create …` (chapter 9.4), then `make secrets-set-dns FILE=/path/sa.json DELETE_SOURCE=1`, `make secrets-check`.
- [ ] **Step 6: Commit** (after approval) — `feat: store GCP DNS credentials in macOS keychain`

### Task 7: Project kubeconfig and transparent cluster access (CLAUDE.md 13.2)

**Files:**
- Create: `scripts/kube.sh`, `tests/kube.bats`
- Modify: `scripts/lib.sh` (`use_project_kubeconfig`, `global_kubeconfig_fingerprint`), `Makefile` (`kubectl`, `k9s`, `shell`, `kube-env`)

**Interfaces:**
- Produces: `use_project_kubeconfig` (sets/exports `KUBECONFIG=$CFKD_HOME/kubeconfig`, file 0600, directory 0700),
  `global_kubeconfig_fingerprint [FILE]` (sha256 or `absent`), CLI `scripts/kube.sh env|kubectl|helm|k9s|shell`.

- [x] **Step 1: Failing tests** `tests/kube.bats` (caller's KUBECONFIG is ignored, permissions, `env` output, kubectl stub sees project kubeconfig, fingerprint).
- [x] **Step 2: Implementation, tests green, shellcheck.**
- [x] **Step 3: Manual** — `make kubectl ARGS="config get-contexts"` does not change `~/.kube/config`.

### Task 6: Acceptance phase 0
- [ ] `make test` (shellcheck + bats) green.
- [ ] `make prereqs` without `fail`.
- [ ] `make config-show` shows `SYSTEM_DOMAIN`, `APPS_DOMAIN`, `CERT_SANS` for `DOMAIN=kind.cfapps.cool`.
- [ ] `make dns-check` green (after `make dns` by the user), also offline.
- [ ] `make secrets-check` green (key as file `.secrets/gcp-dns-credentials.json` or in the Keychain).
- [ ] `~/.kube/config` remains unchanged for all targets.
- [ ] `README.md` extended with quickstart phase 0 (4 commands).
