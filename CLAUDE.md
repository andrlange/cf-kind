# CLAUDE.md — cf-kind-demo

Small automation that, on Apple Silicon Macs, rolls out a **Cloud Foundry demo environment** based on
[`cloudfoundry/kind-deployment`](https://github.com/cloudfoundry/kind-deployment) within a few minutes and tears it down completely again —
including a **service marketplace** (MySQL, PostgreSQL 18 + pgvector, Valkey, RabbitMQ via Open Service Broker API) and an
**Apps-Manager-like web UI**. The environment must **stay stable when the host's network/IP changes** (Wi-Fi switch,
hotspot, customer Wi-Fi, VPN), must be operable **airgapped**, run either with **real Let's Encrypt wildcard certificates**
(start: zone `cfapps.cool`) or self-signed, and remain **easy to handle** throughout.

**Language (binding): English everywhere in the repository** — CLAUDE.md, README and all Markdown docs, plans,
comments in scripts and configs (`config.env.example`, Brewfile, Makefile help), user-facing log/error messages,
test names, and commit messages. Goal: reach an international audience. Conversation with the maintainer may be German.
Existing German content is translated in roadmap phase **L** (see `docs/superpowers/plans/2026-09-22-roadmap.md`).

---

## 1. Scope

### In Scope
- **One command to set up** (`make up`), **one to tear down** (`make down`), one for a complete reset (`make nuke`).
- **Selectable Kubernetes base** (`K8S_PROVIDER`): `kind` (default, upstream reference) and optionally `k3d` (chapter 4). Docker Desktop's built-in Kubernetes was evaluated and rejected (4.1).
- **Prerequisite check and installation** via Homebrew (`make prereqs` / `Brewfile`), idempotent, also on "foreign" Macs.
- **Network robustness**: CF API, UAA, UI and apps remain reachable across IP changes, DNS changes and without internet.
- **Airgapped operation**: `make up`, `cf push` (incl. staging), service provisioning and the demo run **without internet** once the
  artifact buffer is filled (`make airgap-fill`). The source is a local **Artifact Keeper outside the cluster** (chapter 6).
- **Service automation** via the **Open Service Broker API**: `cf marketplace`, `cf create-service`, `cf bind-service`, service keys,
  sharing, plan updates for at least **MySQL, PostgreSQL 18 + pgvector, Valkey, RabbitMQ** (chapter 7).
- **Developer experience**: web UI à la Apps Manager, CLI plugins, demo apps with bindings, guided demo script (chapter 8).
- **Real TLS certificates**: before `make up`, a **domain is specified** (`DOMAIN`, start: `kind.cfapps.cool` → `*.sys.` / `*.app.`) or
  `TLS_MODE=selfsigned` is chosen. Wildcard certificates via Let's Encrypt **DNS-01** with a simple request (`make certs`) and
  automatic renewal; the names still always point to `127.0.0.1` (chapter 9).
- **Resilience after Docker Desktop restart / Mac sleep**: detect and repair (`make doctor`, `make repair`).
- **CPU architecture**: transparency about which parts still need amd64/Rosetta, step-by-step migration to arm64-native (chapter 5).
- **Portability** between Apple Silicon Macs (M1–M4+; 16 GB RAM minimum, **32 GB recommended** with services + Artifact Keeper).

### Out of Scope
- Production, multi-user, HA, persistence beyond `make down` (except the artifact buffer).
- Intel Macs, Linux, Windows (may work, but are not tested).
- Forks of CF components — we **wrap** upstream. Exceptions: own arm64 builds of buildpack dependencies, own service broker, small patches.
- Public reachability of the demo from the internet (DNS names are public, but point to `127.0.0.1`); HTTP-01 challenges.
- Routing isolation segments (not possible in kind upstream).
- Access to the demo from other devices on the network (deliberately only `127.0.0.1`, which is exactly what makes us IP-independent).
- Security scanning/SBOM in the local Artifact Keeper (Trivy, OpenSearch, DependencyTrack stay off).
- Production-grade service features: backups, multi-site, TLS between app and service, usage reports (at most stretch goals).
- Further K8s bases (OrbStack, Colima, Rancher Desktop, minikube, Docker Desktop kubeadm mode) — rationale in chapter 4.

---

## 2. Upstream: cloudfoundry/kind-deployment (research as of 2026-09-22, commit `fb845c8`)

| Topic | Upstream behavior |
|---|---|
| Entry point | `make up` = `create-kind` → `init` (certs/secrets in `temp/`) → `install` (`helmfile sync`) |
| Teardown | `make down` = `kind delete cluster --name cfk8s` + Compose stacks `cache` and `nfs` down + `rm -rf temp` |
| Cluster | Name `cfk8s`, 1× control-plane + 2× worker (one of them Diego cell, label `cloudfoundry.org/cell=true` + taint), CNI **Cilium without kube-proxy** (optionally Calico), FeatureGate `PodAndContainerStatsFromCRI` |
| Ports on the host | `extraPortMappings` 80, 443, 2222 (cf ssh), 32000–32019 (TCP router) → NodePorts 31080/31443/31222 on the worker |
| Domains | `api.cf.127-0-0-1.nip.io`, `*.apps.127-0-0-1.nip.io`, `*.blobstore.127-0-0-1.nip.io` → **always 127.0.0.1**. Hard-coded in `gateway.yaml`, `helmfile.yaml.gotmpl`, `certs/all-in-one.conf`, `Makefile`; in the CF charts as values (`systemDomain`, `appDomains`, blobstore host, `advertiseDomain`) → switchable to `DOMAIN` via patch/values (chapter 9) |
| TLS | own CA from `init.sh` (365 days), **one** secret `all-in-one-tls` for external hostnames **and** internal mTLS names; gateway listener `https` references it |
| In-cluster DNS | CoreDNS rewrite `*.127-0-0-1.nip.io` → Istio gateway service (does not depend on nip.io inside the cluster) |
| Login | `make login` → `cf login -a https://api.cf.127-0-0-1.nip.io -u ccadmin -p $CC_ADMIN_PASSWORD --skip-ssl-validation` (password in `temp/secrets.sh`) |
| Bootstrap | `make bootstrap` (org/space `test`, feature flags, Java/Node/Go/Binary buildpacks), `make bootstrap-complete` for all |
| Tools | `kind` (0.32.0), `kubectl`, `helm`, `helmfile`, `yq`, `crane` are downloaded **version-pinned via curl into `./bin`** (`scripts/tools.sh`) |
| Charts | Helm repos nats, istio, cilium (HTTP), `oci://ghcr.io/cloudfoundry/helm/*` (CF components), Bitnami (postgresql, minio) |
| Caching | Pull-through registries (`docker-io`, `ghcr-io`, `quay-io`, image `registry:3`) in Docker network `kind`, containerd mirror via `/etc/containerd/certs.d/<registry>/hosts.toml`; volumes `cache_*` survive `make down` |
| Helper containers | `alpine/openssl`, `linuxserver/openssh-server`, `alpine` (in `init.sh`), `erichough/nfs-server`, `nginx:alpine` (NFS stack) |
| Included services | only `nfsbroker` (volume services); **no** data services, **no** web UI, **no** metrics stack |
| Env switches | `INSTALL_OPTIONAL_COMPONENTS=false` (without credhub/loggregator/nfs/…), `DISABLE_CACHE=true`, `CNI=calico` |
| Duration | first run 5–20 min, afterwards 2–7 min (with warm cache) |
| Resources | Docker Desktop ≥ 8 GB RAM (upstream tested: M2, 16 GB, Docker Desktop 4.59) |

**Requirements of the Diego cell on the node** (from k8s-rep chart 0.7.0 / `k8s-garden-client`), relevant for every K8s base:
privileged `rep` DaemonSet with hard-wired hostPaths (`/run/containerd/containerd.sock`, `/var/lib/containerd`, `/var/run/containerd`,
`/run/systemd`, `/var/lib/kubelet/pods`, `/var/lib/rep/*`) → **real containerd at default paths, no cri-dockerd**; app pods with
`hostUsers: false` (user namespaces), hostPorts (CNI with portmap), ImageVolumes; rep reads kubelet stats (`:10250/stats/summary`).
`cf push --docker-image` pulls via rep's own containerd client and **ignores `certs.d` mirrors** (airgap gap, chapter 6).

Upstream is included **as a pinned Git checkout** under `upstream/` (fixed commit in `upstream.lock`).
Upstream files are **not edited**. Adjustments via env variables, own scripts before/after the upstream targets
or documented patches in `patches/` that are applied on checkout. Patches are needed for Docker Desktop, k3d and airgap.

---

## 3. Prerequisites

### Hardware / OS
- Apple Silicon (`uname -m` = `arm64`), current macOS.
- Physical RAM: 16 GB minimum (CF alone), **32 GB recommended** (CF + 4 services + Artifact Keeper + UI).
  Docker Desktop: CF alone 8–12 GB, with services 16+ GB; ≥ 6 CPUs; ≥ 60 GB disk in the Docker VM plus 15–30 GB artifact buffer.

### Container runtime
- **Docker Desktop** ≥ 4.4x (tested locally: 4.91): Apple Virtualization Framework, **Rosetta enabled**, `docker compose` v2,
  Docker Desktop's built-in **Kubernetes must stay disabled** (it writes into global kubeconfigs, see 4.1).
- Podman is not supported. If Podman Desktop is installed in parallel, the Docker context `desktop-linux` must be active.

### Tools via Homebrew (`Brewfile`)
| Tool | Brew | Purpose | Required |
|---|---|---|---|
| Docker Desktop | `cask "docker-desktop"` | container runtime for kind | yes |
| cf CLI v8 | `tap "cloudfoundry/tap"`, `brew "cloudfoundry/tap/cf-cli@8"` | Login, push, services | yes |
| jq | `brew "jq"` | Scripts | yes |
| dnsmasq | `brew "dnsmasq"` | local resolution of `*.127-0-0-1.nip.io` (offline / DNS rebind protection) | yes |
| crane | `brew "crane"` | inspect images/manifests, airgap filling | yes |
| kubectl, helm | `brew "kubectl"`, `brew "helm"` | provider adapters, service operators | yes |
| make, git, curl | Xcode CLT (`xcode-select --install`) | upstream Makefile | yes |
| lego | `brew "lego"` | ACME client for Let's Encrypt wildcards via DNS-01 (provider `gcloud`, `acme-dns`, …) | with `TLS_MODE=letsencrypt` |
| mkcert | `brew "mkcert"` | locally trusted CA for `TLS_MODE=selfsigned` (browser without warning) | optional |
| k3d | `brew "k3d"` | only for `K8S_PROVIDER=k3d` | optional |
| k9s | `brew "k9s"` | debugging / live demo of the cluster | optional |
| kind, helmfile, yq | — | upstream downloads them itself into `upstream/bin`; airgapped from the artifact buffer | auto |
| cf plugins | `cf install-plugin` (from AK) | log-cache-cli, app-autoscaler, multiapps | optional |

`make prereqs` checks the architecture, installs missing brew packages (`brew bundle`), checks Docker Desktop (running, RAM/CPU, Rosetta,
containerd image store; `~/Library/Group Containers/group.com.docker/settings-store.json`) and free host ports
(80/443/2222/32000–32019, UI port) and says **clearly what to do**. Airgapped, `brew` is not available → only check there.

---

## 4. Kubernetes base: provider model (easy to handle)

Selection via `K8S_PROVIDER` in `config.env`. **Both supported providers run on Docker Desktop** — so the presenter needs only *one* runtime.

| Provider | Role | Short assessment |
|---|---|---|
| `kind` | **Default / reference** | exactly like upstream and its CI, full control (Cilium, port mappings, mirrors, kubeconfig written only to the project file). |
| `k3d` | optional, later | brew-installable, multi-node, `registries.yaml` for mirrors, `-p 80:80@loadbalancer`, `--kubeconfig-update-default=false`. But: **containerd paths of k3s** (`/run/k3s/containerd`, `/var/lib/rancher/k3s/agent/containerd`) → patch k8s-rep hostPaths. |

Deliberately **not** supported: **Docker Desktop's built-in Kubernetes** (both modes, see 4.1), **OrbStack** (1 node, flannel, paid for
commercial use), **Colima/Rancher Desktop** (1 node, k3s paths, hard with Cilium), **minikube** (possible, but no added value over kind).

### 4.1 Docker Desktop's built-in Kubernetes — evaluated and rejected (2026-09-22)
Tried as a "zero install" provider (kind mode, 3 nodes, enabled by patching `settings-store.json`). Rejected because it conflicts with the
binding rule "no global kubeconfig" (13.2):
- Docker Desktop writes its `docker-desktop` context into the file named by the `KUBECONFIG` of the process that starts it — in the test
  it was added to another project's kubeconfig **and made the current-context** (restored immediately).
- Its own health check nevertheless reads **`~/.kube/config`** and fails if that file is missing or a dangling symlink
  ("reading kubeconfig: stat ~/.kube/config: no such file or directory") — the feature cannot work without a global kubeconfig.
- Further limitations found in the research: CNI (kindnet) and kube-proxy fixed (no Cilium, no CF network policies), NodePorts not reachable,
  no port mappings or FeatureGates, node state must be re-applied after every Docker restart.

Consequence: `K8S_PROVIDER=docker-desktop` is rejected by `validate_config`; `docs/PREREQUISITES.md` tells users to keep Docker Desktop's
Kubernetes **disabled**. Docker Desktop itself remains the container runtime for `kind`.

### 4.2 Provider `kind`
Upstream unchanged (+ own Docker network with fixed subnet, static node IPs, port mappings on `127.0.0.1` instead of `0.0.0.0`).
According to kind, multi-node restarts work since v0.15 ([PR #2775](https://github.com/kubernetes-sigs/kind/pull/2775)); [#2045](https://github.com/kubernetes-sigs/kind/issues/2045) is still open → test.

### 4.3 Provider `k3d` (phase 9, optional)
Cluster with `--k3s-arg --flannel-backend=none --disable-network-policy --disable=traefik,servicelb?` + Cilium (bpf mount workaround),
cell label/taint via `--k3s-node-label`/`--node-taint`, mirrors via `registries.yaml`, ports via `@loadbalancer`,
k8s-rep hostPaths via helmfile `jsonPatches` to the k3s containerd paths.

### 4.4 Adapter interface (`providers/<name>.sh`)
Every provider implements the same functions; the Makefile knows only these:
`preflight` · `ensure` (create/enable, idempotent) · `delete` / `reset` · `kube_context` · `cni_mode` (`cilium|calico|none|chained`) ·
`expose` (NodePort+mapping | LoadBalancer | @loadbalancer, check: 80/443/2222 answer on 127.0.0.1) · `label_taint_cells` ·
`configure_mirrors` + `node_network` · `health` / `repair` (node Ready, cell label, mirrors, ports; reapply after restart/sleep).

The feature matrix per provider is maintained in `docs/providers.md` once a second provider exists.

---

## 5. CPU architecture: amd64 vs. arm64

Status analysis 2026-09-22 (raw data: `docs/image-arch-report.tsv`, via `crane manifest` against all 68 images from charts, `versions.yaml`,
Compose files and scripts of upstream `fb845c8`).

### 5.1 Container images: almost everything arm64-native
- **67 of 68 images are multi-arch with `linux/arm64`**: all `ghcr.io/cloudfoundry/k8s/*`, the stacks `cflinuxfs4`/`cflinuxfs5`, all
  buildpack images, Cilium, Istio, NATS, bitnamilegacy postgres/minio, `kindest/node`, `registry:3`, helper containers.
- **Only exception: `erichough/nfs-server:latest` (amd64-only)** — NFS stack, only with `INSTALL_OPTIONAL_COMPONENTS=true`.
  Replace with a multi-arch NFS image, build it ourselves, or disable NFS for the demo.
- Service operators and images (chapter 7) are all arm64-capable according to research. **The Stratos container image is amd64-only** (chapter 8).

### 5.2 Buildpack dependencies: the actual reason for Rosetta
The CF buildpacks are **"uncached"** (zips ~6–8 MB, no dependencies included). During staging the buildpack downloads the runtime from
`https://buildpacks.cloudfoundry.org/dependencies/...` — there are **only `linux_x64` builds** there. The app then runs as an amd64 binary in the
arm64 `cflinuxfs4` container of the Diego cell, which only works via Rosetta/binfmt in the Docker VM.

| Buildpack | amd64-only dependencies | arm64 priority |
|---|---|---|
| nodejs | node, python | **high** (standard demo `hello-js`) |
| java | openjdk, zulu, sapmachine, jvmkill, (profilers/agents) | **high** (Spring Boot demos) |
| go | go (+ dep, glide, godep — outdated) | medium |
| staticfile | nginx | medium |
| python | python, libffi, libmemcache, miniconda/miniforge | medium |
| binary | — (app brings its binary → build arm64) | trivial |
| ruby / php / dotnet-core / nginx | ruby, jruby, php, httpd, dotnet-*, nginx, openresty, node | low |
| r | only noarch entries | — |

Alternative: **Cloud Native Buildpacks** (`lifecycle: cnb` in the manifest, cnbapplifecycle) with Paketo — Paketo provides arm64 dependencies.
Adopt lessons learned from a prior reference implementation (Paketo mirror, Java buildpack pin for Spring Boot 4).

### 5.3 Strategy
1. **Short term**: Rosetta is mandatory; `make doctor` checks binfmt for x86_64 (test container `--platform linux/amd64`).
2. **Medium term**: provide arm64 variants for node, openjdk, go, nginx, python and rewrite buildpack `manifest.yml` to AK URLs
   (repack, checksums). Sources: a) official arm64 upstream builds that run on cflinuxfs4 (Ubuntu 22.04), b) self-built via
   `binary-builder` in an arm64 cflinuxfs4 container, c) otherwise keep amd64. Selection logic modeled on
   a proven buildpack-dependency selector from a prior reference implementation (never construct file names, always from manifest/URI+checksum).
3. Status per dependency in `docs/arm64-status.md`. Target picture: demo with Node, Java and Staticfile app runs with **Rosetta disabled**.

---

## 6. Airgap: Artifact Keeper as outer system

### 6.1 Why outside the cluster
The buffer must survive `make down`/`make nuke` and a provider switch, be available **before** the cluster and must not depend on CF.
Hence its own **Docker Compose stack on the Mac** (`airgap/`), own volumes, reachable in the node network of the respective provider and
on `127.0.0.1:<port>` for host tools.

### 6.2 Basis: specs from a prior reference implementation
| Source (reference implementation) | Use here |
|---|---|
| Artifact Keeper Kubernetes manifest | Components + versions (backend `ghcr.io/artifact-keeper/artifact-keeper-backend:1.8.1`, web `…-web:1.8.0`, `postgres:16-alpine`) → translate into Compose, **without OpenSearch and Trivy** |
| Artifact Keeper repo setup script | Repo creation via API (docker/ghcr/quay proxy, generic, helm, npm/maven) → slimmed down as `airgap/configure.py` |
| Artifact list + pull script | Format of the artifact list → model for `airgap/artifacts.yaml` |
| Buildpack-dependency selector | Select buildpack dependencies by arch+stack |
| Garage (`dxflrs/garage:v2.3.0`) | S3 blob backend for large artifacts |
| Artifact Keeper operations notes | Pitfalls (see below) |

Additionally from the reference implementation: an image mirror script (`crane copy --platform linux/arm64`, multiple source registries,
isolated `DOCKER_CONFIG`) and a Paketo buildpack mirror script.

Known AK pitfalls: large files only via the **chunk upload session API**; **AK 1.8.1 `helm` repos do not accept OCI pushes** → put CF charts
(`oci://ghcr.io/cloudfoundry/helm/*`) into a `docker`/`oci` repo; check the `/v2/token` multi-scope bug; raise ingress/proxy timeouts for large pushes.
Upstream uses `bitnamilegacy/*` (frozen, not allowed in the reference implementation) → mirroring is mandatory, and note it as a patch candidate.

### 6.3 What must be buffered
| Artifact class | Online source | Repo in AK | Consumer |
|---|---|---|---|
| CF images (~68, `docs/image-arch-report.tsv`) | docker.io, ghcr.io, quay.io | docker proxy | containerd of the nodes (mirror → AK instead of `registry:3`), host Docker for helper containers |
| Node images (`kindest/node`, Docker Desktop K8s images, k3s) | docker.io | docker proxy | provider (`docker desktop kubernetes images`, `KubernetesImagesRepository`) |
| Service operators + operand images (CNPG, pgvector extension, mariadb, valkey, rabbitmq) | ghcr.io, docker.io, quay.io | docker proxy | operators; redirect the operators' default images to the mirror via values/CR |
| Helm charts (CF, operators) | HTTP repos + OCI | helm or oci | `helmfile sync` |
| CLI tools, cf plugins, Stratos binary | GitHub releases, dl.k8s.io, get.helm.sh | generic | `tools.sh` (redirect URL), `cf install-plugin` |
| Buildpack zips | buildpack images (`crane export`) | generic | `cf create-buildpack` |
| **Buildpack dependencies** | `buildpacks.cloudfoundry.org` (+ own arm64 builds) | generic → S3 | staging → manifest pointing to AK URL **or** cached buildpacks |
| Demo app dependencies | npm, Maven Central, PyPI | npm/maven/pypi proxy | `cf push` (simplest variant: vendored apps) |
| `cf push --docker-image` images | any | docker proxy | **rep ignores `certs.d`** → reference images directly with the AK hostname |

App containers of the Diego cell must reach the AK (DNS in the cluster, TLS with demo CA or HTTP locally) — open point.

### 6.4 Workflows
- `make airgap-up` / `airgap-down`: start/stop AK + Garage + Postgres (data is kept).
- `make airgap-fill`: while online, pull all artifacts from 6.3 (idempotent, checksums), report what is missing.
- `make airgap-verify`: block egress or turn Wi-Fi off, then `make up && make services && make demo` — nothing may go to the internet.
- `make airgap-export` / `airgap-import`: buffer as a tarball to another Mac (USB stick scenario), optional.
- `AIRGAP=true|false` in `config.env`: with `true` everything uses the AK exclusively and aborts instead of falling back to the internet.

---

## 7. Service automation (Open Service Broker API)

### 7.1 Goal
Developers experience the marketplace as in commercial Cloud Foundry distributions: `cf marketplace` → `cf create-service postgres small db` (async) → `cf bind-service` →
`VCAP_SERVICES` is detected automatically by Spring Boot (java-cfenv) / Node / Python. Plus `cf create-service-key`, `cf share-service`,
`cf update-service -p` (resize) and `dashboard_url` (e.g. RabbitMQ management UI).

### 7.2 Architecture: a lean Go broker that creates operator CRs
- **Broker**: Go with `code.cloudfoundry.org/brokerapi/v13`, as a deployment in the cluster (namespace `cf-services`), arm64 image from the AK.
  Registration via `cf create-service-broker` (+ `enable-service-access`); space-scoped as an option for non-admin demos.
- **Provision** → namespace/CR per instance, **always async**; **last_operation** reads the Ready condition of the CR;
  **Bind** → own user per binding (user CR / managed role / ACL), credentials + tags returned; **Unbind** deletes the user;
  **Deprovision** cleans up CR, secrets and **PVCs**.
- **State** not in a ConfigMap, but derived from the CRs themselves (labels/annotations with instance/binding ID).
- Why not Cloud Service Broker (OpenTofu brokerpaks): no Terraform state, no arm64 release, slow binds; only if brokerpaks
  are to be shown explicitly. Minibroker, Service Catalog, Korifi approach: archived.
- **Basis for reuse: an existing Go broker from a prior reference implementation** (Go, brokerapi v11, provisioners for CNPG,
  Valkey, RabbitMQ, S3/Garage, plus a broker test script) and a second marketplace broker (`postgres-ai` with pgvector, OpenBao secrets, AI connector).
  Platform-neutral OSB v2 → adopt with upgrade to brokerapi v13. **Do not adopt**: plain-text password in `deployment.yaml`
  (broker credentials are generated on `make up`, like `temp/secrets.sh`).

### 7.3 Services (minimum scope)
| Service (catalog) | Backend | Plans (demo) | Tags / URI scheme |
|---|---|---|---|
| `postgres` | **CloudNativePG** 1.30 (`Cluster` CR), PG 18 `ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie`, **pgvector** as ImageVolume extension `ghcr.io/cloudnative-pg/pgvector:0.8.6-18-trixie` + `Database` CR with `extensions: [vector]` | `small`, `vector` (pgvector enabled), optional `ha` (3 instances) | `postgresql`, `postgres` · `postgres://` + `jdbcUrl` |
| `mysql` | **mariadb-operator** 26.x (`MariaDB`, `Database`, `User`, `Grant` CRs), official multi-arch mariadb images | `small`, optional `galera` | `mysql`, `mariadb` · `mysql://` + `jdbcUrl` |
| `valkey` | official **valkey/valkey** 9.x via `valkey-io/valkey-helm` or StatefulSet, requirepass/ACL user per binding; `valkey-io/valkey-operator` (alpha, cluster mode only) only as an option | `small`, optional `cluster` | `redis`, `valkey` · `redis://` |
| `rabbitmq` | **RabbitMQ Cluster Operator** 2.23 + **Messaging Topology Operator** 1.20 (`Vhost`, `User`, `Permission` per binding) | `small`, optional `ha` (3 nodes) | `rabbitmq` · `amqp://`, `dashboard_url` → management UI |

Further candidates from the reference implementation (later): `s3` (Garage), `postgres-ai`, `openbao-secrets`, `ai-connector` (Ollama/LM Studio on the Mac).
No Bitnami, no Oracle MySQL operator images (arm64 uncertain).

### 7.4 Credential format (binding)
Always `uri` **and** individual fields `hostname`, `port`, `name`, `username`, `password`, for SQL additionally `jdbcUrl`; set field `type`
(lesson learned: otherwise Spring bindings crash); **FQDN hostnames** (`<svc>.<ns>.svc.cluster.local`), since app containers do not run in the service namespace.
Check CredHub-backed bindings (included in kind-deployment).

### 7.5 Prerequisites / open questions
- App containers of the Diego cell must reach ClusterIP services: check CNI path and **ASGs** (application security groups), create them if needed.
- pgvector via ImageVolume needs K8s ≥ 1.35 and containerd ≥ 2.1 on the nodes — check per provider; fallback: own PG18 image with pgvector.
- RAM budget: per service `small` ~256–512 MiB; operators together ~1 GB.
- `make services` installs operators + broker and registers it; `make services-test` provisions/binds/deletes each service once.

---

## 8. Developer experience

### 8.1 Web UI (Apps Manager replacement)
The web UIs of commercial Cloud Foundry distributions are proprietary. Options:
| Option | Assessment |
|---|---|
| **Stratos 5.5.x** (`cloudfoundry/stratos`, active again since Aug. 2026, Angular 20+, UAA SSO, marketplace, logs, autoscaler UI) | **First choice.** Start as a **native darwin-arm64 binary on the host** (container image is amd64-only) or push as a zip into CF. Register a UAA client, mind self-signed certs. Risk: one main maintainer, V3 migration not fully completed. |
| **Custom Apps Manager clone** (from the reference implementation: Spring Boot 4 / Kotlin / HTMX, CF API v3, marketplace with parameter forms) | **Alternative with full control** over demo flow and branding. For classic CF: UAA login instead of a ServiceAccount token, remove platform-specific parts. |
| Own thin UI | only if neither fits (effort MVP 1–2 weeks, with marketplace/logs another 3–4). |

Decision after a spike: test Stratos against the kind CF (login, apps, marketplace, logs); if there are gaps → port the custom Apps Manager clone.

### 8.2 CLI & tooling
- cf plugins: `log-cache-cli` (`cf tail`), `app-autoscaler-cli-plugin`, `multiapps-cli-plugin` (needs MultiApps Controller) — optional.
- **App Autoscaler**: only available as CF apps via MTA (`cloudfoundry/app-autoscaler`), needs Postgres + MultiApps Controller → stretch goal.
- Metrics: kind-deployment has no metrics stack → stretch goal (log-cache is sufficient for `cf app`/`cf logs`).
- `cf ssh` (port 2222), service keys, user-provided services, route services can be demonstrated.

### 8.3 Demo apps (`examples/`, vendored, airgap-capable)
- `hello-js` (upstream), a **Spring Boot app** with Postgres + Valkey + RabbitMQ bindings (java-cfenv), a **pgvector/RAG demo**
  (modeled on a Spring PetClinic variant with Spring AI + Ollama), a Staticfile app.
- `make demo` pushes, binds, prints URLs; `docs/demo-script.md` as presenter guide (10- and 30-minute variant).

---

## 9. TLS certificates: Let's Encrypt wildcards or self-signed

### 9.1 Basic idea
**Public domain, local resolution.** The certificates are real, publicly trusted Let's Encrypt wildcards, but the
names resolve to **`127.0.0.1`**. This is made possible by the **DNS-01 challenge**: Let's Encrypt only checks a TXT record
in the public zone; the server does not need to be reachable from the internet. This preserves IP independence and
Wi-Fi robustness, and `cf login` / browser / Stratos no longer need `--skip-ssl-validation`.

### 9.2 Pre-Task: choose domain or self-signed (`config.env` or `make configure`)
Two domain paths (platform and apps subdomain, a common CF layout):

| Variable | Default / example | Meaning |
|---|---|---|
| `TLS_MODE` | `letsencrypt` \| `selfsigned` | `selfsigned` = upstream behavior with `127-0-0-1.nip.io` (default if no domain is set) |
| `DNS_ZONE` | `cfapps.cool` | public zone in GCP Cloud DNS (project `<gcp-project>`), where TXT (and optionally A) records land |
| `DOMAIN` | `kind.cfapps.cool` | base of this demo environment |
| `SYS_SUBDOMAIN` | `sys` | → **system domain** `SYSTEM_DOMAIN=sys.<DOMAIN>` (CF API, UAA, login, logging, SSH, UI, AK, dashboards) |
| `APP_SUBDOMAIN` | `app` | → **apps domain** `APPS_DOMAIN=app.<DOMAIN>` (default shared domain for `cf push` routes) |
| `DOMAIN_LAYOUT` | `split` \| `flat` | `split` (default): `sys.<DOMAIN>` + `app.<DOMAIN>`. `flat`: system **and** apps domain = `<DOMAIN>`, i.e. `api.kind.cfapps.cool`, `hello.kind.cfapps.cool` |
| `ACME_DNS_PROVIDER` | `gcloud` (alternatives: `acme-dns`, …) | lego DNS provider of the zone |
| `ACME_DNS_CREDENTIALS` | `keychain:cf-kind-demo-gcp-dns` or `~/.config/cf-kind-demo/gcp-dns.json` | GCP service account key, **never in the repo** |
| `ACME_EMAIL` | `admin@cfapps.cool` | LE account |
| `ACME_ENV` | `staging` \| `prod` | test against staging first (rate limits!) |
| `PUBLIC_DNS_RECORDS` | `true` | additionally create public A records → `127.0.0.1` in Cloud DNS (chapter 9.4) |

**Why a dedicated subdomain (`DOMAIN=kind.cfapps.cool`) instead of the zone apex:** the demo names stay separate from
anything else that may live in the zone, the local resolver (`/etc/resolver/<DOMAIN>`) overrides only this subdomain, and it can be
varied per Mac/presenter (`DOMAIN=kind-<name>.<zone>`). Anyone with a zone reserved for the demo can set `DOMAIN=DNS_ZONE`.

### 9.3 Certificate & naming scheme
A wildcard covers only **one** label. Hence one certificate with these SANs (layout `split`):

| SAN | covers |
|---|---|
| `*.sys.<DOMAIN>` | `api.`, `login.`, `uaa.`, `log-stream.`, `log-cache.`, `doppler.`, `ssh.`, `ui.`, `ak.`, `rabbitmq-<id>.` (service dashboards) … |
| `*.app.<DOMAIN>` | all app routes `<app>.app.<DOMAIN>` |
| `*.blobstore.sys.<DOMAIN>` | Minio bucket hosts (virtual-host style, `MINIO_DOMAIN=blobstore.sys.<DOMAIN>`) — two labels, hence its own wildcard |
| `*.<DOMAIN>` + `<DOMAIN>` | single names directly below the base, **also covers `sys.<DOMAIN>` and `app.<DOMAIN>`** |

> Let's Encrypt rejects names that a wildcard in the same request already covers ("redundant with a wildcard domain",
> occurred in the staging run 2026-09-22). `sys.<DOMAIN>`/`app.<DOMAIN>` are therefore **not** listed separately in the SAN list;
> a unit test (`tests/lib.bats`) prevents regressions.

**Layout `flat` (simplest variant, one main wildcard):** SANs `*.<DOMAIN>`, `<DOMAIN>`, `*.blobstore.<DOMAIN>`.
System domain = apps domain = `<DOMAIN>`. So that apps do not occupy platform hostnames, the Cloud Controller reserves them via
`system_hostnames` (api, login, uaa, log-stream, log-cache, doppler, ssh, ui, ak …) — set via CAPI values and check in `make doctor`.
Downside: app and platform names share one namespace; service dashboards and apps can collide. For the first local
implementation, `flat` with `DOMAIN=kind.cfapps.cool` is acceptable; `split` remains the default because it is the common CF layout.

Mapping to upstream (there `cf.<base>` / `apps.<base>` / `blobstore.<base>`): `systemDomain → sys.<DOMAIN>`,
`appDomains → [app.<DOMAIN>]`, blobstore → `blobstore.sys.<DOMAIN>`. Further app domains (e.g. `*.internal` routes, TCP domain
`tcp.sys.<DOMAIN>`) follow the same scheme or need an additional SAN.
Only the **gateway certificate** is replaced (new secret `public-tls`, switch listener `https` to it via patch). The **internal
upstream CA remains** for mTLS between CF components (`all-in-one-tls` with internal names) — no public certs for internal names.

### 9.4 Quick guide: create a real wildcard certificate (start: `cfapps.cool` / GCP Cloud DNS)
Prerequisite: zone `cfapps.cool` in Cloud DNS (GCP project `<gcp-project>`) and a service account with DNS permissions — already
a dedicated DNS service account with role `roles/dns.admin`.
For this project create a **separate key** (better: a separate SA `cf-kind-demo-dns`), do not reuse keys of other projects.

**Provide credentials:** lego (`--dns gcloud`) authenticates via **service account JSON** (`GCE_SERVICE_ACCOUNT_FILE` or
content in `GCE_SERVICE_ACCOUNT`) or Application Default Credentials, in each case with `GCE_PROJECT`. A short-lived OAuth access token
is not sufficient for automatic renewals (expires after ~1 h) — so for `make certs-autorenew` store the **SA key**.
Recommended: in the **macOS Keychain** instead of as a file (`make secrets-set-dns` reads the JSON once; scripts fetch it via
`security find-generic-password -s cf-kind-demo-gcp-dns -w` into an env variable only at runtime). Tokens/keys **never in chat, repo or logs**.

```bash
# 1) One-time: create SA key and store it in the Keychain
gcloud iam service-accounts keys create /tmp/gcp-dns.json \
  --iam-account=<dns-service-account>@<gcp-project>.iam.gserviceaccount.com --project=<gcp-project>
make secrets-set-dns FILE=/tmp/gcp-dns.json   # -> Keychain, file is deleted afterwards

# 2) Set domain (pre-task)
make configure TLS_MODE=letsencrypt DNS_ZONE=cfapps.cool DOMAIN=kind.cfapps.cool   # sys/app = defaults

# 3) Public records (optional, idempotent): *.sys / *.app / *.blobstore.sys -> A 127.0.0.1
make dns-public     # gcloud dns record-sets create/update in zone <gcp-project>

# 4) Request certificate — staging first, then prod
make certs ACME_ENV=staging
make certs ACME_ENV=prod
#   internally: GCE_PROJECT=<gcp-project> GCE_SERVICE_ACCOUNT="$(keychain)" lego --dns gcloud \
#     --email "$ACME_EMAIL" --accept-tos --path ~/.config/cf-kind-demo/lego \
#     -d "*.sys.$D" -d "*.app.$D" -d "*.blobstore.sys.$D" -d "*.$D" -d "$D" run
#   (flat: -d "*.$D" -d "$D" -d "*.blobstore.$D")

# 5) Local resolution (one-time sudo) + deploy
make dns        # /etc/resolver/kind.cfapps.cool -> dnsmasq -> 127.0.0.1 (offline too)
make up         # creates secret public-tls, gateway uses it
cf login -a https://api.sys.kind.cfapps.cool   # without --skip-ssl-validation
cf push hello   # -> https://hello.app.kind.cfapps.cool
```
The public A records (step 3) are a convenience (Macs without `make dns`, colleagues' machines); what matters for offline/Wi-Fi robustness
is the local resolver. The DNS rebind protection of some routers filters public answers pointing to `127.0.0.1` — another reason to resolve locally.

Alternative without cloud credentials on the Mac: **acme-dns delegation** (as in a prior reference implementation): one-time CNAME `_acme-challenge.<name> → <uuid>.acme.<zone>` per wildcard, after which lego only needs
acme-dns API credentials. Or import existing certificates (`make certs-import CERT_DIR=...`).

### 9.5 Renewal
- Certificates are stored **on the host** (`~/.config/cf-kind-demo/lego/`), not in the cluster: they survive `make down`/`nuke` and
  provider switches, and frequent re-creation consumes **no** Let's Encrypt rate limits (among others max. 5 identical certificates/week).
  Hence deliberately **no cert-manager in the short-lived demo cluster**.
- `make certs` is idempotent: remaining validity ≥ 30 days → do nothing; otherwise reissue and update secret `public-tls`
  (Istio gateway reloads secret changes without restart).
- **Lesson learned:** lego v5 has **no** `renew`; renewal = fresh issuance. Therefore **issue into a temporary directory
  and swap atomically only on success** — never delete the old cache beforehand.
- Automation: `make certs-autorenew` installs a **launchd agent** (`~/Library/LaunchAgents/…cf-kind-demo.certs.plist`, daily,
  runs only with internet, otherwise silent retry). `make up` and `make doctor` also check the remaining validity.
- **Airgap/demo day:** renewal needs internet. `make doctor` warns at < 21 days of remaining validity; before an offline phase run
  `make certs FORCE_RENEW=1`. Let's Encrypt validity periods will get shorter in the coming years — keep thresholds configurable.

### 9.6 Self-signed mode
- Default without domain: upstream CA + `127-0-0-1.nip.io`, `cf login --skip-ssl-validation`.
- Optionally **own domain + self-signed** (e.g. offline without DNS provider) and, with `mkcert`, a local CA in the macOS Keychain
  (`make trust-ca`) so that browsers do not warn. The `cf` CLI then still needs `--skip-ssl-validation` or `SSL_CERT_FILE`.

### 9.7 Implementation in upstream (patch `patches/domain-and-tls`)
Parameterize the domain: gateway listener hostnames (`*.sys.<DOMAIN>`, `*.app.<DOMAIN>`, `*.blobstore.sys.<DOMAIN>` or with `flat`
`*.<DOMAIN>` instead of `*.127-0-0-1.nip.io`), `system_hostnames` with `flat`, CoreDNS rewrite, `MINIO_DOMAIN`, chart values (`systemDomain`, `appDomains`, blobstore host, `advertiseDomain`),
SANs in `certs/all-in-one.conf`, login URL in the Makefile. Additionally gateway `certificateRefs` to `public-tls` with `TLS_MODE=letsencrypt`.
UAA redirect URIs for Stratos/the custom UI to `ui.sys.<DOMAIN>`. In self-signed mode without a domain the upstream scheme
(`cf.`/`apps.` under `127-0-0-1.nip.io`) stays unchanged, so that the patch remains minimally invasive.

---

## 10. Network robustness (core requirement)

**Basic principle: nothing depends on the host's IP.** All endpoints run via `127.0.0.1`.

**Resolver follows the stack (no sudo per switch):** `/etc/resolver/<DOMAIN>` stays permanently; only the user-owned dnsmasq
config switches mode. `make up` → **active** (every name below `DOMAIN` → `127.0.0.1`, works offline); `make down` → **passthrough**
(forward to the DNS servers of the current network via `/etc/resolv.conf`, so real names resolve normally while the stack is down).
Stopping the agent instead would break resolution for the domain entirely (macOS does not fall back). Public loopback records from
`make dns-public` bypass this and keep resolving to `127.0.0.1` — remove them with `make dns-public-remove` when the local resolver is set up.

| Risk on network change | Measure |
|---|---|
| `nip.io` or public DNS for `DOMAIN` not reachable (offline, captive portal, airgapped) | dnsmasq locally: `address=/<DOMAIN>/127.0.0.1`, plus `/etc/resolver/<DOMAIN>` (`nameserver 127.0.0.1`) — applies to `127-0-0-1.nip.io` and e.g. `kind.cfapps.cool` (covers `sys.` and `app.`). One-time `sudo`. Optionally additionally public records `*.sys.`/`*.app.<DOMAIN>` → `127.0.0.1` via `make dns-public`. |
| DNS rebind protection in router/corporate DNS (e.g. FRITZ!Box) | as above |
| Docker network collides with Wi-Fi subnet (e.g. 172.18.0.0/16) | provider `kind`: create network `kind` beforehand with an unusual subnet (`10.213.0.0/16`); `make doctor` warns |
| Node IPs change after Docker restart ([kind#2045](https://github.com/kubernetes-sigs/kind/issues/2045)) | `kind`: static node IPs (to be verified); all providers: `make repair` or quick recreate with warm buffer |
| Docker Desktop K8s loses cluster/labels/mirrors after restart | `make repair` reapplies labels, taints, mirrors; detect the reset case and redeploy |
| Upstream DNS changes | CoreDNS → Docker's embedded DNS follows the host; `make doctor` tests |
| Buildpacks download dependencies during staging | Artifact Keeper (chapter 6) |
| Time drift of the Docker VM after sleep → UAA token errors | `make doctor` compares time of host vs. node |
| Port mappings/LoadBalancer on `0.0.0.0` → demo reachable in foreign Wi-Fi | bind explicitly to `127.0.0.1` |

**Acceptance test** (`docs/testplan.md`, per provider): environment running → switch Wi-Fi → Wi-Fi off → restart Docker Desktop → Mac sleep:
afterwards `cf apps`, `curl -k https://hello-js.apps.127-0-0-1.nip.io`, a new `cf push`, `cf create-service` + `bind-service` work
(if necessary after `make repair`). Additionally: `make nuke` (without buffer) → `make up` → `make services` → `make demo` **without internet**.

---

## 11. Planned structure

```
.
├── CLAUDE.md
├── README.md               # short guide for demo presenters
├── Makefile                # our targets, delegates to providers/, upstream/, airgap/, services/
├── Brewfile
├── config.env              # K8S_PROVIDER, AIRGAP, subnet, optional components, service selection, upstream ref
├── upstream/               # pinned checkout of cloudfoundry/kind-deployment (do not edit)
├── upstream.lock
├── patches/                # e.g. CNI=none, gateway LoadBalancer, k3s hostPaths, airgap URLs — each with rationale
├── providers/              # kind.sh (k3d.sh later) — adapter interface chapter 4.4
├── airgap/                 # compose.yaml (AK + Garage), configure.py, artifacts.yaml, fill.sh, verify.sh
├── services/
│   ├── broker/             # Go broker (brokerapi v13), Dockerfile (arm64)
│   ├── operators/          # helmfile for CNPG, mariadb-operator, valkey, rabbitmq (+ topology)
│   └── catalog.yaml        # services/plans as configuration
├── certs/                # certs.sh (lego wrapper), launchd plist template; the certificates themselves live in ~/.config/cf-kind-demo/
├── ui/                     # Stratos start/config or custom Apps Manager clone
├── buildpacks/             # repack logic: manifest URIs → AK, arm64 dependencies
├── scripts/                # lib.sh, prereqs.sh, dns-setup.sh, doctor.sh, repair.sh
├── examples/               # demo apps (vendored)
└── docs/                   # image-arch-report.tsv, arm64-status.md, providers.md, testplan.md, demo-script.md
```

## 12. Make targets (target picture)

| Target | Function |
|---|---|
| `make prereqs` | check tools/Docker/Rosetta/ports, install missing ones via brew when online |
| `make configure` | Pre-Task: write `TLS_MODE`, `DNS_ZONE`, `DOMAIN`, `SYS_SUBDOMAIN`/`APP_SUBDOMAIN`, provider interactively or via parameters into `config.env` |
| `make secrets-set-dns` | import GCP DNS service account key into the macOS Keychain |
| `make dns-public` | create/update public A records `*.sys`/`*.app`/`*.blobstore.sys` → `127.0.0.1` in Cloud DNS (idempotent) |
| `make certs` / `certs-autorenew` / `certs-import` / `trust-ca` | request/renew wildcard certificate, launchd renewal, import foreign certs, trust local CA |
| `make dns` / `dns-remove` | set up/remove local resolver for `127-0-0-1.nip.io` (sudo) |
| `make airgap-up` / `airgap-fill` / `airgap-verify` | start Artifact Keeper, fill it, test offline run |
| `make up` | prereqs → dns-check → (airgap-up) → provider `ensure` → upstream install → login → bootstrap |
| `make services` / `services-test` | install and register operators + broker / test all services once |
| `make ui` | start Stratos (or the custom UI), print URL + login |
| `make demo` | push demo apps, bind services, print URLs |
| `make status` | provider, cluster, CF API, services, UI, AK, credentials in compact form |
| `make doctor` / `repair` | checks from chapters 4, 5, 9 and 10, self-healing |
| `make arch-report` | regenerate `docs/image-arch-report.tsv` (after upstream/operator bump) |
| `make down` | remove CF + services; AK, caches and provider settings remain |
| `make nuke` | additionally caches, networks, `upstream/bin`, the provider's cluster; with `NUKE_AIRGAP=1` also the AK buffer |

Target times: `up` with filled buffer **≤ 7 min** (offline too), `services` **≤ 3 min**, `down` **≤ 1 min**.

## 13. Conventions

### 13.1 Architecture pattern: test-driven development (binding)
Every change to logic is created **test-first** in the cycle **Red → Green → Refactor**:
1. **Red**: first write a test that describes the desired behavior and **watch it fail** (check the error message — does it fail for the right reason?).
2. **Green**: only as much code as needed for the test to pass.
3. **Refactor**: clean up, tests stay green. Only then continue.

Rules:
- **No production code without a previously failing test.** Bug fixes start with a test that reproduces the bug.
- **Design for testability**: logic in pure functions (input → output, no side effects), side effects (brew, docker, kubectl,
  sudo, launchctl, security, network) thinly around them. Renderers (`render_*`) produce config/manifests as text and are unit-testable;
  scripts can be loaded via `source`, `main` runs only on direct execution (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`).
- **Test levels**:
  - *Unit* (`tests/*.bats`, bats-core): pure functions, renderers, validation — fast, without Docker/network/sudo, isolated in `$BATS_TEST_TMPDIR`
    (redirect `CFKD_HOME`, `CFKD_CONFIG`). Mandatory for every function with logic.
  - *Go* (service broker): `go test ./...` with table-driven tests; Kubernetes via fake clients (`client-go/fake`), OSB flows via
    `httptest` against the brokerapi handler.
  - *Integration* (`tests/integration/`, marker `CFKD_INTEGRATION=1`): against a real cluster/provider — `make up`, `cf push`, service lifecycle.
  - *Acceptance* (`docs/testplan.md`): network change, offline, Docker restart, sleep — manual or semi-automated per provider.
- `make test` (shellcheck + bats + `go test`) must be green before every commit; integration tests before completing each roadmap phase.
- Tests are specification: names describe behavior in English (`@test "flat layout uses the base for system and apps"`).
- Plans (`docs/superpowers/plans/`) phrase every task as test → implementation → green → commit.

### 13.2 Kubernetes access: no global kubeconfig (binding)
Other projects on the same Mac use `kubectl` with `~/.kube/config` (e.g. contexts of other local clusters).
cf-kind-demo must **neither read nor write this file nor change the current-context**.

- **A project-specific kubeconfig**: `$CFKD_HOME/kubeconfig` (`~/.config/cf-kind-demo/kubeconfig`, `0600`), exactly one context
  `cf-kind-demo`. Every script sets `KUBECONFIG` to it **explicitly** (`lib.sh: use_project_kubeconfig`); no script relies
  on the user's environment. Helm/helmfile/kubectl/k9s get it via `KUBECONFIG` or `--kubeconfig`.
- **Provider adapters must prevent writing to `~/.kube/config`**:
  - `kind`: `kind create cluster --kubeconfig "$CFKD_HOME/kubeconfig"` (or `KUBECONFIG` set) — upstream `create-kind.sh` otherwise writes
    globally → patch or own call. `kind get kubeconfig --name cfk8s` to regenerate.
  - `k3d`: `--kubeconfig-update-default=false --kubeconfig-switch-context=false`, then `k3d kubeconfig get`.
  - Docker Desktop's built-in Kubernetes is not supported for exactly this reason (4.1).
- **Transparency is still fully given** — everything in the cluster remains viewable and controllable:
  - `make kubectl ARGS="get pods -A"` and `make k9s` (use the project kubeconfig),
  - `make shell`: subshell with `KUBECONFIG` set and a prompt hint, in which normal `kubectl`/`helm`/`k9s` work,
  - `eval "$(make -s kube-env)"` or optionally `.envrc` for direnv (`export KUBECONFIG=~/.config/cf-kind-demo/kubeconfig`),
  - `make status` shows the path of the kubeconfig and the context.
- **Same principle for the cf CLI**: `CF_HOME=$CFKD_HOME/cf` for every call (`lib.sh: use_project_cf_home`), so that
  `~/.cf/config.json` of other foundations remains untouched; access via `make cf ARGS=…`, `make shell` or `eval "$(make -s kube-env)"`.
- Tests check: after `make up`/`down`, `~/.kube/config` (hash) is unchanged, and the
  scripts run with `KUBECONFIG=/dev/null` in the caller's environment.

### 13.3 Secrets never enter Git (binding)
The repository has a public GitHub remote (`git@github.com:andrlange/cf-kind.git`). Real secrets — passwords, private keys,
certificates, service-account JSON, tokens, kubeconfigs, `config.env` — must never be committed or pushed.

- **Where secrets live**: only outside Git — `.secrets/` (gitignored, `0700`/`0600`), the macOS Keychain, or `~/.config/cf-kind-demo/`
  (certificates, lego account, kubeconfig, `CF_HOME`). Upstream's generated `upstream/temp/` (CA, passwords) is gitignored with `upstream/`.
- **Enforced by hooks**: `.githooks/pre-commit` (gitleaks on staged changes) and `.githooks/pre-push` (gitleaks on all commits
  being pushed) — enabled with `make hooks` (`git config core.hooksPath .githooks`); `make prereqs` checks they are active.
  Never bypass them with `--no-verify` for real content.
- **Full scan**: `make secrets-scan` (gitleaks over the entire history) before the first push and before every release/tag.
- **Test fixtures** use obviously fake values (e.g. `"private_key":"x"`) or keys generated at test runtime in `$BATS_TEST_TMPDIR` —
  never real material.
- **If a secret is ever committed**: do not push; rewrite the local history. If it was already pushed: rotate the secret first,
  then clean the history — deleting the file in a new commit is not enough.

### 13.4 Further conventions

- Bash with `set -euo pipefail`, `shellcheck`-clean; only macOS built-in tools + Brewfile tools (mind BSD `sed`/`date`). Go for the broker, Python only for AK configuration.
- In zsh contexts always quote image references (`"${img}:latest"` — otherwise `$var:l…` is interpreted as a zsh modifier).
- All scripts **idempotent**: running `make up`/`down`/`services`/`airgap-fill` multiple times must never do harm.
- **Easy to handle**: every error ends with a concrete instruction for action; no click instructions where automation is possible.
- **Airgap first**: no new component, no script step without an entry in `airgap/artifacts.yaml`. Nothing "just downloads somewhere later".
- Pin artifacts **by version and, where possible, digest**, fixed operator versions (no `releases/latest`); no new `latest` tags.
- New images **multi-arch with arm64**; amd64-only only with an entry in `docs/arm64-status.md`. Do **not** introduce new **Bitnami images/charts**.
- Do not commit secrets; broker, AK and CF credentials are generated locally. DNS provider credentials, LE account key and certificates
  live only under `~/.config/cf-kind-demo/` (`0700`/`0600`), never in the repo or in the cluster except as a TLS secret.
- New hostnames only in the scheme from chapter 9.3: platform/UI/dashboards under `sys.<DOMAIN>` (one label), apps under `app.<DOMAIN>` — otherwise the wildcard is missing.
- Changes to the Docker Desktop configuration (`settings-store.json`) and `sudo` only after announcement, with backup and a way back.
- Show destructive actions (`nuke`, volume deletion, `reset-cluster`) beforehand and have them confirmed, except with `FORCE=1`.
- On upstream updates: bump `upstream.lock`, `make arch-report`, `airgap-fill`, acceptance test per provider, result in `docs/testplan.md`.

## 14. Open points / to be verified

1. Docker Desktop: are the settings keys (`KubernetesEnabled`, `KubernetesMode`, `KubernetesNodesCount`, `KubernetesNodesVersion`, `KubernetesImagesRepository`) reliable via file patch? Does the cluster survive restarts in 4.91 (for-mac#7745)?
2. Docker Desktop: does k8s-rep (user namespaces, ImageVolume, kubelet stats without FeatureGate) run on the `desktop-*` nodes? Does the LoadBalancer bind to 127.0.0.1?
3. `CNI=none` on Docker Desktop: which CF features are visibly missing (c2c policies, ASGs)? Cilium chaining as a way out?
4. kind: are static node IPs via `docker network connect --ip` stable with Cilium without kube-proxy? Is a pre-created network `kind` with its own subnet OK? Default node image of kind 0.32 (K8s ≥ 1.35 for pgvector ImageVolume)?
5. Buildpack dependencies airgapped: manifest repack vs. cached buildpacks vs. CNB/Paketo — what is more robust?
6. Which arm64 upstream binaries (Node, JDK, Go, nginx) run unchanged on cflinuxfs4?
7. Reachability of AK and service ClusterIPs from app containers (DNS, TLS/CA, ASGs, network policies).
8. containerd mirror directly to AK (auth for private proxy repos) or `registry:3` as an intermediate layer?
9. Stratos 5.5 against classic CF in kind: UAA client, self-signed certs, marketplace, log streaming (RLP gateway exposed?).
10. RAM budget on 16 GB Macs: is slim CF (`INSTALL_OPTIONAL_COMPONENTS=false`) + 4 services + UI realistic?
11. Behavior with Podman Desktop installed in parallel (Docker context / socket conflicts).
12. TLS: do CAPI/UAA/Gorouter fully accept the switch to `sys.<DOMAIN>`/`app.<DOMAIN>` via values (also `login.`, `uaa.`, `doppler.`, `log-stream.`, `ssh.`, TCP domain)? Which hostnames fall outside the wildcard scheme?
13. TLS: does the Istio gateway reload an updated `public-tls` secret without restart (renewal path)? Does the Diego cell/`cf push` need the public chain internally?
14. TLS: separate SA `cf-kind-demo-dns` with a minimal role (`roles/dns.admin` at zone level instead of project, or a custom role with only `dns.changes.*`/`dns.resourceRecordSets.*`)? Does `make dns-public` need more permissions than DNS-01?
