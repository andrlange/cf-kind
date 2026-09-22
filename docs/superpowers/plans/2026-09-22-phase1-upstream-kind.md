# Phase 1 — Upstream + Provider `kind` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make up` builds a working Cloud Foundry on this Mac (provider `kind`, `127-0-0-1.nip.io`, self-signed), `make smoke` pushes `hello-js` and calls it, `make down` cleans up completely — without touching `~/.kube/config` or `~/.cf/`.

**Architecture:** `upstream/` is a pinned checkout of `cloudfoundry/kind-deployment` (commit in `upstream.lock`), patches from `patches/*.patch` are applied idempotently. The cluster is created **by the provider adapter** (`providers/kind.sh`), not by upstream `create-kind.sh` — this way we control kubeconfig, port binding (`127.0.0.1`) and later subnet/mirrors. Afterwards the upstream targets `init` and `install` run with `KUBECONFIG` set. `scripts/cluster.sh` orchestrates, `scripts/cf.sh` wraps the cf CLI with a project-specific `CF_HOME`.

**Tech Stack:** Bash 3.2, kind (version from upstream `scripts/tools.sh`), helmfile, docker compose, cf CLI v8, bats-core.

**Spec:** `CLAUDE.md` chapter 2, 4.2, 4.4, 11, 12, 13.1, 13.2.

## Global Constraints
- TDD (CLAUDE.md 13.1): every function with logic first as a failing bats test.
- No global configuration: `KUBECONFIG=$CFKD_HOME/kubeconfig`, `CF_HOME=$CFKD_HOME/cf` for every call.
- Do not edit upstream files; deviations only as a patch in `patches/` or in the adapter.
- Host port mappings bind to `127.0.0.1`, not `0.0.0.0`.
- Phase 1 always runs with `127-0-0-1.nip.io` (domain/TLS patch follows in phase 3); if `DOMAIN` is set, a warning is issued.
- Upstream pin: `https://github.com/cloudfoundry/kind-deployment` @ `fb845c8410868d31ba06f912d68756b86073c2ef`.

## File Structure
| File | Responsibility |
|---|---|
| `upstream.lock` | repo URL + commit |
| `scripts/upstream.sh` | checkout/update to the pin, apply patches, `make -C upstream …` with the right environment |
| `providers/kind.sh` | adapter: `provider_preflight`, `provider_ensure`, `provider_delete`, `provider_kube_context`, `provider_health` |
| `scripts/cluster.sh` | `up`, `down`, `status`: load provider, install upstream |
| `scripts/cf.sh` | `login`, `bootstrap`, `smoke`, `cf …` with project-specific `CF_HOME` |
| `tests/upstream.bats`, `tests/provider_kind.bats`, `tests/cluster.bats`, `tests/cf.bats` | unit tests |

### Task 1: Upstream checkout (`scripts/upstream.sh`)
**Interfaces:** Produces `read_lock KEY` (url|commit), `upstream_ensure` (clones/checks out, rc 0 if on pin), `apply_patches DIR` (idempotent via `.cfkd-patches` = sha256 of all patches), `upstream_make TARGET…` (sets `KUBECONFIG`, `CF_HOME`, `INSTALL_OPTIONAL_COMPONENTS`).
- [ ] Tests: parse lock file; `apply_patches` on a temp Git repo applies once and is a no-op on the second run; a changed patch set leads to reset + re-application.
- [ ] Implementation, green, shellcheck, commit.

### Task 2: Provider `kind` (`providers/kind.sh`)
**Interfaces:** Produces `render_kind_config FILE` (upstream `kind.yaml` + `listenAddress: "127.0.0.1"` per `extraPortMapping`), `render_mirror_hosts_toml CACHE REMOTE` (containerd `hosts.toml`), adapter functions see above; cluster name `cfk8s`.
- [ ] Tests: every `hostPort` line gets exactly one `listenAddress`, otherwise the file stays the same; `hosts.toml` contains `server` and mirror host; `provider_kube_context` = `kind-cfk8s`.
- [ ] Implementation (cluster via `kind create cluster --kubeconfig`, taint on cell nodes, registry caches via upstream Compose, mirror config via `docker exec`, NFS only with optional components), green, commit.

### Task 3: Orchestration (`scripts/cluster.sh`) + `scripts/cf.sh`
**Interfaces:** Produces `load_provider NAME` (sources `providers/NAME.sh`, checks mandatory functions), `use_project_cf_home`, `cf_api_url` (`https://api.$SYSTEM_DOMAIN`); CLI `cluster.sh up|down|status`, `cf.sh login|bootstrap|smoke|cf …`.
- [ ] Tests: `load_provider` rejects missing adapters/functions; phase 1 domain override enforces nip.io; `CF_HOME` is set independently of the caller; `cf_api_url` for nip.io.
- [ ] Implementation, Makefile targets `up down status login bootstrap smoke cf`, green, commit.

### Task 4: Integration & acceptance
- [ ] `make up` on this Mac (provider `kind`), `make smoke` → HTTP 200 from `hello-js`, `make status`, `make down`.
- [ ] `~/.kube/config` and `~/.cf/config.json` unchanged (fingerprint before/after).
- [ ] Update README status, commit.
