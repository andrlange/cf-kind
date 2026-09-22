# Prerequisites

Everything a Mac needs before `make up`, and what cf-kind-demo changes on your system. Most steps are automated.
`make prereqs` checks all of them and tells you exactly what to do when something is missing.

## Checklist

| # | Requirement | How | Automated |
|---|---|---|---|
| 1 | Apple Silicon Mac, ≥ 16 GB RAM (32 GB recommended) | — | checked |
| 2 | Homebrew | [brew.sh](https://brew.sh) | checked |
| 3 | Docker Desktop, configured as below | install + settings | installed if missing, settings checked |
| 4 | CLI tools (cf CLI, jq, dnsmasq, lego, …) | `make prereqs` | yes |
| 5 | Configuration: domain and TLS mode | `make configure` | yes |
| 6 | Local DNS resolver | `make dns` (asks for sudo once) | yes |
| 7 | *Only for Let's Encrypt:* a public DNS zone in Google Cloud DNS + service-account key | see [below](#lets-encrypt-certificates-optional) | partly |
| 8 | Git hooks for contributors | `make hooks` | checked |

Minimal path without an own domain (self-signed, `*.127-0-0-1.nip.io`):

```bash
make prereqs
make dns
make up
```

## 1. Hardware and macOS

- Apple Silicon (M1 or newer). Intel Macs are not supported.
- 16 GB RAM minimum for Cloud Foundry alone; 32 GB recommended once services and the artifact cache are added.
- About 60 GB free disk space for Docker images, plus 15–30 GB for the (optional) airgap artifact cache.
- A current macOS version.

## 2. Docker Desktop

Docker Desktop is the container runtime. The Kubernetes cluster itself is created by [kind](https://kind.sigs.k8s.io/) inside Docker.
`make prereqs` installs Docker Desktop via Homebrew if `/Applications/Docker.app` is missing.

Open **Docker Desktop → Settings** and set:

| Setting | Value | Why |
|---|---|---|
| **General → Virtual Machine Manager** | Apple Virtualization framework | stable, recommended by upstream |
| **General → Use Rosetta for x86_64/amd64 emulation** | **on** | classic CF buildpacks still download amd64-only runtimes during staging |
| **Resources → Memory** | ≥ 8 GB (16 GB recommended) | Cloud Foundry runs about 40 pods |
| **Resources → CPUs** | ≥ 6 | faster startup and staging |
| **Resources → Disk usage limit** | ≥ 60 GB | images and caches |
| **Kubernetes → Enable Kubernetes** | **off** | see the warning below |

> **Keep Docker Desktop's built-in Kubernetes disabled.** When enabled, Docker Desktop writes a `docker-desktop` context into
> whatever kubeconfig the `KUBECONFIG` variable points to (or `~/.kube/config`) and makes it the current context. This silently
> redirects `kubectl` in other projects. cf-kind-demo never touches global Kubernetes configuration. It uses its own kubeconfig
> (see [Isolation](#isolation-what-is-and-is-not-touched)), so Docker Desktop's Kubernetes is neither needed nor supported.

Also check:
- The active Docker context is `desktop-linux` (`docker context show`). This matters if Podman Desktop or other runtimes are installed.
- Podman, OrbStack and Colima are not supported.

## 3. CLI tools

```bash
make prereqs          # installs missing tools from the Brewfile, then runs all checks
make prereqs-check    # checks only (use this when offline/airgapped)
```

Installed from the [`Brewfile`](../Brewfile):
- **Required:** cf CLI v8, jq, dnsmasq, crane, kubectl, helm, lego, mkcert, gitleaks, shellcheck, bats-core.
- **Optional:** k9s.
- **Pinned by upstream:** kind, helmfile and yq, downloaded into `upstream/bin` in the versions pinned by `cloudfoundry/kind-deployment`.

Homebrew ≥ 7 requires trusting third-party taps. `make prereqs` runs `brew trust` for the official Cloud Foundry tap
(`cloudfoundry/tap/cf-cli@8`) only.

Also checked:
- Free host ports 80, 443 and 2222 (required) and 32000–32019 (TCP routing, optional).
- Rosetta works: an amd64 test container is started.
- The secret-scanning git hooks are active.

## 4. Configuration (pre-task)

```bash
make configure                       # interactive
make configure KEY=VALUE …           # non-interactive
make config-show                     # show the configuration and the derived domains
```

Local values are written to `config.env`, which is gitignored. The defaults are documented in [`config.env.example`](../config.env.example).

| Scenario | Command |
|---|---|
| No own domain, self-signed (default) | nothing to do: `*.127-0-0-1.nip.io` is used |
| Own domain, self-signed | `make configure DOMAIN=demo.example.org` |
| Own domain, Let's Encrypt | `make configure TLS_MODE=letsencrypt DNS_ZONE=example.org DOMAIN=demo.example.org ACME_EMAIL=you@example.org GCP_PROJECT=<gcp-project>` |

There are two domain layouts:

| Layout | Platform | Apps |
|---|---|---|
| `split` (default) | `api.sys.demo.example.org` | `hello.app.demo.example.org` |
| `flat` | `api.demo.example.org` | `hello.demo.example.org` |

Use a **dedicated subdomain** such as `demo.example.org`, not the apex of a zone that serves other hosts.
The local resolver then overrides only that subdomain.

## 5. Local DNS resolver

All demo names resolve to `127.0.0.1`. This makes the environment independent of Wi-Fi changes, captive portals and DNS rebinding
protection in routers, and it also works offline.

```bash
make dns          # one-time setup, asks for your sudo password once
make dns-check    # verify
make dns-remove   # undo everything below
```

`make dns` changes your system in exactly these places:

| What | Where | Needs sudo |
|---|---|---|
| dnsmasq as a **user** launch agent on `127.0.0.1:53535` (never as root) | `~/Library/LaunchAgents/io.cf-kind-demo.dnsmasq.plist`, config in `~/.config/cf-kind-demo/` | no |
| Per-domain resolver files for your demo domain and `127-0-0-1.nip.io` (marked `# managed by cf-kind-demo`; files of other tools are never touched) | `/etc/resolver/<domain>` | yes, once |
| Narrow sudoers rule that allows **only** `dscacheutil -flushcache` and `killall -HUP mDNSResponder` without a password, so switching modes can flush the macOS DNS cache | `/etc/sudoers.d/cf-kind-demo` (checked with `visudo`) | yes, once |

The resolver follows the stack, and switching needs no sudo:
- After `make up` it is **active**: demo names → `127.0.0.1`.
- After `make down` it is **passthrough**: demo names are forwarded to your current network's DNS, so real hosts resolve normally.

## 6. Let's Encrypt certificates (optional)

Real, browser-trusted wildcard certificates are issued with [lego](https://go-acme.github.io/lego/) through the **DNS-01** challenge.
Your Mac never has to be reachable from the internet: Let's Encrypt only checks a TXT record in your public zone.

You need:
1. **A public DNS zone in Google Cloud DNS** (for example `example.org`) in a GCP project.
2. **A service account with DNS permissions** in that project (role `roles/dns.admin`, ideally granted on the zone only). Create a key for it:
   ```bash
   gcloud iam service-accounts create cf-kind-demo-dns --project <gcp-project>
   gcloud projects add-iam-policy-binding <gcp-project> \
     --member "serviceAccount:cf-kind-demo-dns@<gcp-project>.iam.gserviceaccount.com" --role roles/dns.admin
   gcloud iam service-accounts keys create /tmp/dns-key.json \
     --iam-account cf-kind-demo-dns@<gcp-project>.iam.gserviceaccount.com
   ```
3. **Store the key outside Git**, in one of two ways:
   - **macOS Keychain (recommended):** `make secrets-set-dns FILE=/tmp/dns-key.json DELETE_SOURCE=1`
   - **Gitignored file:** move it to `.secrets/dns-key.json` (mode `0600`) and run `make configure ACME_DNS_CREDENTIALS=.secrets/dns-key.json`
4. **Issue the certificate:**
   ```bash
   make certs ACME_ENV=staging   # test against staging first (production has rate limits)
   make configure ACME_ENV=prod
   make certs                    # issues the real certificate; about 10 minutes
   make certs-autorenew          # daily launchd job; renews when fewer than 30 days are left
   ```

Notes:
- Certificates are stored in `~/.config/cf-kind-demo/certs/`, not in the cluster. They survive `make down`, and recreating the environment does not use up Let's Encrypt rate limits.
- Renewal needs internet access. Before an offline demo, run `make certs FORCE_RENEW=1` if `make doctor` warns.
- Some networks intercept outgoing DNS. lego therefore waits a fixed time (`ACME_PROPAGATION_WAIT`, default `120s`) instead of checking propagation itself.
- `make dns-public` can additionally publish `127.0.0.1` A records for the demo names. It is not needed when the local resolver is set up, and those records keep resolving to `127.0.0.1` even while the stack is down (`make dns-public-remove` deletes them).

## 7. Isolation: what is and is not touched

| Global file | Touched? |
|---|---|
| `~/.kube/config` or the file named by `KUBECONFIG` | **never**: the demo cluster uses `~/.config/cf-kind-demo/kubeconfig` |
| `~/.cf/config.json` | **never**: the cf CLI runs with `CF_HOME=~/.config/cf-kind-demo/cf` |
| Your gcloud login | **never**: gcloud calls use a temporary, isolated configuration |
| `/etc/resolver/`, `/etc/sudoers.d/` | only our own, marked files (see [Local DNS resolver](#5-local-dns-resolver)) |

Access the demo cluster and foundation with:

```bash
make kubectl ARGS="get pods -A"
make k9s
make cf ARGS="apps"
make shell                   # subshell with KUBECONFIG and CF_HOME of the demo
eval "$(make -s kube-env)"   # or set them in the current shell
```

`make doctor` fails if the demo cluster ever shows up in `~/.kube/config`.

## 8. For contributors

```bash
make hooks          # gitleaks pre-commit and pre-push hooks; required, checked by make prereqs
make test           # shellcheck + bats unit tests + language check
make secrets-scan   # full secret scan of the git history and all tracked files
```

- **Test-driven development:** every function with logic needs a failing bats test first (see `CLAUDE.md`, chapter 13.1).
- **Bash 3.2 compatibility:** scripts must run with the Bash that ships with macOS.
- **English only:** all repository content must be in English.
- **No secrets:** passwords, keys, certificates and kubeconfigs never enter Git (enforced by the hooks).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `make prereqs` reports busy ports 80/443 | `lsof -nP -iTCP:443 -sTCP:LISTEN` shows the process; stop it |
| amd64 test container fails | enable Rosetta in Docker Desktop (General) and restart Docker Desktop |
| Demo names do not resolve | `make dns-check`; run `make dns` again after macOS updates |
| Names resolve to `127.0.0.1` after `make down` | public records from `make dns-public` still exist: `make dns-public-remove` |
| API unreachable right after `make up` | `make doctor`, then `make repair` |
| Certificate issuance hangs or fails | run `make certs-cleanup`, then retry; check the service account permissions |
