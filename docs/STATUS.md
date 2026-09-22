# Project status

Current state of **cf-kind-demo**, phase by phase. The detailed plans live in
[`docs/superpowers/plans/`](superpowers/plans/), and the full specification in [`CLAUDE.md`](../CLAUDE.md).

_Last updated: 2026-09-22_

| Phase | Topic | Status |
|---|---|---|
| [0](#phase-0--prerequisites) | Prerequisites | ✅ done |
| [1](#phase-1--upstream--provider-kind) | Upstream + provider `kind` | ✅ done |
| [2](#phase-2--provider-docker-desktop) | Provider `docker-desktop` | ⬜ open |
| [3](#phase-3--domain--tls) | Domain & TLS | ✅ done |
| [4](#phase-4--network-robustness) | Network robustness | 🟡 in progress |
| [5](#phase-5--airgap) | Airgap | ⬜ open |
| [6](#phase-6--service-automation) | Service automation | ⬜ open |
| [7](#phase-7--developer-experience) | Developer experience | ⬜ open |
| [8](#phase-8--arm64-native-buildpack-dependencies) | arm64-native buildpack dependencies | ⬜ open |
| [9](#phase-9--provider-k3d-optional) | Provider `k3d` (optional) | ⬜ open |
| [L](#phase-l--language-english) | Language: English | ✅ done |

Legend: ✅ done · 🟡 in progress · ⬜ open

---

## Phase 0 — Prerequisites
**Status:** ✅ done

- `make prereqs` checks this Mac (Apple Silicon, Docker Desktop version/memory/CPUs, containerd image store, Rosetta,
  free ports, cf CLI, active git hooks) and installs missing tools via Homebrew (`Brewfile`).
- `make configure` / `make config-show`: pre-task for domain, TLS mode and provider; derived system/apps domains and certificate SANs.
- Local resolver (`make dns`): user-level dnsmasq launch agent plus `/etc/resolver/<domain>`; sudo is needed only once.
- DNS-01 credentials from the macOS Keychain or a gitignored file (`make secrets-set-dns`, `make secrets-check`).
- Project-local kubeconfig and `CF_HOME`: `~/.kube/config` and `~/.cf` are never touched (`make kubectl`, `make k9s`, `make shell`).

## Phase 1 — Upstream + provider `kind`
**Status:** ✅ done

- [`cloudfoundry/kind-deployment`](https://github.com/cloudfoundry/kind-deployment) pinned in `upstream.lock`;
  patches from `patches/` are applied idempotently.
- Provider adapter `providers/kind.sh`: creates the cluster itself (project kubeconfig, host ports bound to `127.0.0.1` only).
- `make up`, `make down`, `make status`, `make login`, `make bootstrap`, `make smoke` and `make cf` all work.
- Verified: `hello-js` is pushed and answers over HTTPS. `make down` cleans up in about 5 seconds, and the image caches are kept.

## Phase 2 — Provider `docker-desktop`
**Status:** ⬜ open

Goal: use Docker Desktop's built-in Kubernetes (kind mode) as a zero-install alternative.

Planned work:
- Enable Kubernetes by patching the settings file.
- Label and taint the Diego cell node.
- Run without Cilium (`CNI=none` patch).
- Expose the gateway through a `LoadBalancer` service.
- Configure registry mirrors via `docker exec`.
- Re-apply this state after Docker restarts.

Needs the maintainer's approval before the Docker Desktop settings are changed.

## Phase 3 — Domain & TLS
**Status:** ✅ done

- `patches/10-domain-and-tls.patch` makes the CF domains configurable in two layouts:
  - `split`: `api.sys.<domain>` and `*.app.<domain>`
  - `flat`: everything directly under `<domain>`

  Without a domain, the output renders identical to upstream.
- `make certs` issues Let's Encrypt wildcard certificates via lego and DNS-01 against Google Cloud DNS:
  - staging first, then prod
  - atomic swap: a failed run keeps the old certificate
  - fixed propagation wait, which works on networks that intercept DNS
- `make certs-autorenew` installs a daily launchd job. `make certs-cleanup` removes stale challenge records.
- The internal upstream certificate carries the demo domain SANs, because gorouter verifies its backends against them.
- Verified:
  - `https://api.sys.kind.cfapps.cool` and `https://hello-js.app.kind.cfapps.cool` pass strict TLS verification with a Let's Encrypt certificate.
  - `cf login` works without `--skip-ssl-validation`.

## Phase 4 — Network robustness
**Status:** 🟡 in progress

Done:
- `make doctor` checks the configuration, the resolver mode, subnet overlap with the current Wi-Fi, certificate expiry, cluster, CF API, clock drift, and that `~/.kube/config` is untouched.
- `make repair` re-applies the provider state, the gateway certificate and the resolver.
- The Docker network `kind` is pinned to a rarely used subnet (`KIND_SUBNET`, default `10.213.0.0/16`).
- The resolver follows the stack. `make up` switches it to **active** (demo names → `127.0.0.1`, works offline). `make down` switches it to **passthrough** (names resolve through the current network's DNS). No sudo is needed for either switch.

Open:
- **Negative DNS caching in macOS:** after `make down` → `make up`, the names can be unreachable for up to 5 minutes. A fix is being decided (a narrowly scoped sudoers rule to flush the cache, or a wait-and-hint approach).
- **Acceptance tests** (Wi-Fi change, offline, Docker Desktop restart, Mac sleep), to be documented in `docs/testplan.md`.
- **Static node IPs** for multi-node kind clusters across Docker restarts.

## Phase 5 — Airgap
**Status:** ⬜ open

Goal: `make up`, `cf push` and service provisioning work without any internet connection.

Planned:
- A local Artifact Keeper with Garage S3 as a Compose stack outside the cluster.
- `make airgap-fill`, `airgap-verify`, `airgap-export` and `airgap-import`.
- containerd mirrors pointing to the Artifact Keeper.
- Mirrored buildpack dependencies.

## Phase 6 — Service automation
**Status:** ⬜ open

Goal: a service marketplace via the Open Service Broker API, served by a thin Go broker (brokerapi v13) that creates operator resources:

| Service | Backend |
|---|---|
| MySQL | mariadb-operator |
| PostgreSQL 18 + pgvector | CloudNativePG |
| Valkey | official Valkey Helm chart |
| RabbitMQ | Cluster Operator + Messaging Topology Operator |

Acceptance: create → bind → the app uses `VCAP_SERVICES` → unbind → delete, for all four services.

## Phase 7 — Developer experience
**Status:** ⬜ open

Goal: an Apps-Manager-like web UI. The first candidate is Stratos 5.5 (darwin-arm64 binary with a UAA client).
Also planned are demo apps with service bindings (Spring Boot, a pgvector/RAG demo, Node, Staticfile), `make demo`, and a presenter script.

## Phase 8 — arm64-native buildpack dependencies
**Status:** ⬜ open

Classic buildpacks download **amd64-only** runtimes (node, openjdk, go, nginx, python) during staging, so Rosetta is currently required.
Goal: provide arm64 variants, repack the buildpack manifests, and have the demo run with Rosetta disabled.
The image-level analysis is in [`docs/image-arch-report.tsv`](image-arch-report.tsv).

## Phase 9 — Provider `k3d` (optional)
**Status:** ⬜ open

k3d as a third provider; this needs patched hostPaths for the k3s containerd layout.

## Phase L — Language: English
**Status:** ✅ done

All repository content is in English: docs, comments, messages and test names.
`make lint-language` is part of `make test`.

---

## Quality gates (all phases)

- **Test-driven development:** bats unit tests and shellcheck run via `make test`. `[[ ]]` assertions are hardened for bash 3.2.
- **Secret scanning:** gitleaks pre-commit and pre-push hooks (`make hooks`), plus a full scan with `make secrets-scan`.
- **No global configuration:** a project-local kubeconfig and `CF_HOME`, plus a guard in `make doctor`.
