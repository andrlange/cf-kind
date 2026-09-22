# cf-kind-demo

Cloud Foundry as a demo environment on Apple Silicon Macs, set up and torn down in minutes. Based on
[`cloudfoundry/kind-deployment`](https://github.com/cloudfoundry/kind-deployment).

Goals:
- **Easy to handle**: one command to set up, one to tear down.
- **Stable across network changes**: all endpoints run via `127.0.0.1`, local DNS resolver, offline too.
- **Airgapped operation possible**: all artifacts come from a local Artifact Keeper.
- **Real TLS certificates**: Let's Encrypt wildcards via DNS-01 (start: `kind.cfapps.cool`) or self-signed.
- **Service marketplace**: MySQL, PostgreSQL 18 + pgvector, Valkey and RabbitMQ via the Open Service Broker API.
- **Developer experience**: web UI in the style of Apps Manager (Stratos) plus demo apps.

Architecture, scope and decisions are in [`CLAUDE.md`](CLAUDE.md), the phases in the
[roadmap](docs/superpowers/plans/2026-09-22-roadmap.md).

## Status

| Phase | Content | Status |
|---|---|---|
| 0 | Prerequisites: tools, configuration (domain/TLS), local DNS, DNS credentials | **done** |
| 1 | Upstream + provider `kind` (reference) | **done** — `make up`, `make smoke` green |
| 2 | Provider `docker-desktop` | planned |
| 3 | Domain & TLS (Let's Encrypt, renewal) | **done** — `https://api.sys.kind.cfapps.cool` with a Let's Encrypt wildcard, strict TLS verification green |
| 4 | Network robustness (`doctor`/`repair`) | **in progress** — `make doctor` green; acceptance tests (Wi-Fi change, offline, Docker restart, sleep) open |
| 5 | Airgap (Artifact Keeper) | planned |
| 6 | Service automation (OSB broker + operators) | planned |
| 7 | Developer experience (UI, demo apps) | planned |
| 8 | arm64-native buildpack dependencies | planned |
| 9 | Provider `k3d` (optional) | planned |
| L | Language: English | **done** — `make lint-language` part of `make test` |

## Prerequisites

- Mac with Apple Silicon and at least 16 GB RAM (32 GB recommended)
- [Homebrew](https://brew.sh)
- Docker Desktop with Rosetta and containerd image store enabled. If it is missing, `make prereqs` installs it.

## Quickstart (Phase 0)

```bash
make prereqs                         # checks the Mac and installs missing tools via brew
make configure TLS_MODE=letsencrypt DOMAIN=kind.cfapps.cool ACME_EMAIL=admin@cfapps.cool
make config-show                     # shows the derived system/apps domains
make dns                             # local resolver: *.kind.cfapps.cool -> 127.0.0.1 (asks once for the sudo password)
make secrets-check                   # GCP DNS key for Let's Encrypt present?
```

GCP DNS key for Let's Encrypt, two variants:
- as file `.secrets/gcp-dns-credentials.json` (gitignored, `0600`), plus `make configure ACME_DNS_CREDENTIALS=.secrets/gcp-dns-credentials.json`
- in the macOS Keychain: `make secrets-set-dns FILE=~/sa.json DELETE_SOURCE=1` (default `ACME_DNS_CREDENTIALS=keychain:cf-kind-demo-gcp-dns`)

## Kubernetes access

cf-kind-demo **never** uses `~/.kube/config`. Other projects that use `kubectl` remain untouched.
The demo cluster has its own kubeconfig at `~/.config/cf-kind-demo/kubeconfig`:

```bash
make kubectl ARGS="get pods -A"      # kubectl against the demo cluster
make k9s                             # k9s against the demo cluster
make shell                           # subshell in which kubectl/helm/k9s point to the demo cluster
eval "$(make -s kube-env)"           # set KUBECONFIG in the current shell
```

Without your own domain, `make prereqs` is sufficient: the environment then uses `127-0-0-1.nip.io` with self-signed certificates.

`make` without arguments lists all targets.

## Starting Cloud Foundry

```bash
make up          # cluster + Cloud Foundry + login + buildpacks (first time 5–20 min)
make smoke       # push hello-js and call it via HTTPS
make status      # nodes, pods, CF API
make cf ARGS="apps"
make down        # tear everything down (image caches remain)
```

The cf CLI uses its own `CF_HOME` (`~/.config/cf-kind-demo/cf`); `~/.cf` of other foundations remains untouched.

## Configuration

The defaults are in [`config.env.example`](config.env.example). `make configure` writes local values to `config.env`;
this file is not checked in. Environment variables override both files.

| Layout | Platform | Apps |
|---|---|---|
| `split` (default) | `api.sys.kind.cfapps.cool` | `hello.app.kind.cfapps.cool` |
| `flat` | `api.kind.cfapps.cool` | `hello.kind.cfapps.cool` |

## Development

**Test-driven development** applies (see `CLAUDE.md`, chapter 13.1): first a failing test, then the code.

```bash
make test        # shellcheck + bats unit tests
```

The scripts must run with Bash 3.2, because macOS ships this version.
