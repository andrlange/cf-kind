# cf-kind-demo — control surface. Logic lives in scripts/, this file only wires it up.
SHELL := /bin/bash
.DEFAULT_GOAL := help

CONFIG_KEYS := K8S_PROVIDER TLS_MODE DNS_ZONE DOMAIN DOMAIN_LAYOUT SYS_SUBDOMAIN APP_SUBDOMAIN \
               ACME_DNS_PROVIDER ACME_DNS_CREDENTIALS ACME_EMAIL ACME_ENV GCP_PROJECT AIRGAP CF_OPTIONAL_COMPONENTS KIND_SUBNET
# pass on only variables that were set explicitly on the command line
CONFIG_ARGS := $(foreach k,$(CONFIG_KEYS),$(if $(filter command line,$(origin $(k))),$(k)=$($(k))))

help: ## This help
	@echo "cf-kind-demo — Cloud Foundry demo on Apple Silicon"
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-18s %s\n", $$1, $$2}'

prereqs: ## check prerequisites and install missing tools via brew
	@scripts/prereqs.sh

prereqs-check: ## check only, install nothing (e.g. airgapped)
	@scripts/prereqs.sh --check

configure: ## pre-task: set domain/TLS/provider (KEY=VALUE … or interactive)
	@scripts/configure.sh $(CONFIG_ARGS)

config-show: ## show configuration including derived domains
	@scripts/configure.sh --show

dns: ## local resolver: dnsmasq agent + /etc/resolver (asks for the sudo password once)
	@scripts/dns.sh setup

dns-check: ## check the local resolver
	@scripts/dns.sh check

dns-remove: ## remove the local resolver (sudo)
	@scripts/dns.sh remove

dns-public: ## public A records *.sys/*.app/… -> 127.0.0.1 in Cloud DNS (idempotent)
	@scripts/dns.sh public

secrets-set-dns: ## store DNS-01 credentials (GCP service account JSON) in the keychain: FILE=… [DELETE_SOURCE=1]
	@scripts/secrets.sh set-dns "$(FILE)" $(if $(DELETE_SOURCE),--delete-source)

secrets-check: ## check that DNS-01 credentials are present
	@scripts/secrets.sh check-dns

up: ## build cluster + Cloud Foundry, log in, bootstrap
	@scripts/cluster.sh up

down: ## tear everything down (image caches are kept)
	@scripts/cluster.sh down

status: ## overview: provider, nodes, pods, CF API
	@scripts/cluster.sh status

doctor: ## health checks: config, resolver, subnet overlap, certificate, cluster, CF API, clock drift
	@scripts/doctor.sh check

repair: ## re-apply provider state and gateway certificate, then run doctor
	@scripts/doctor.sh repair

login: ## cf login as ccadmin (project-local CF_HOME)
	@scripts/cf.sh login

bootstrap: ## org/space test, feature flags, buildpacks
	@scripts/cf.sh bootstrap

smoke: ## push hello-js and call it
	@scripts/cf.sh smoke

cf: ## cf CLI against the demo foundation: ARGS="apps"
	@scripts/cf.sh cf $(ARGS)

upstream: ## bring the upstream checkout to the pin, apply patches
	@scripts/upstream.sh ensure

certs: ## issue/renew the Let's Encrypt wildcard when needed (ACME_ENV=staging|prod, FORCE_RENEW=1)
	@scripts/certs.sh issue

certs-status: ## remaining validity and SANs of the certificate
	@scripts/certs.sh status

certs-cleanup: ## remove leftover _acme-challenge TXT records in Cloud DNS
	@scripts/certs.sh cleanup

certs-autorenew: ## install a daily launchd job for make certs (REMOVE=1 removes it)
	@scripts/certs.sh autorenew $(if $(REMOVE),--remove)

kubectl: ## kubectl against the demo cluster (project kubeconfig): ARGS="get pods -A"
	@scripts/kube.sh kubectl $(ARGS)

k9s: ## k9s against the demo cluster
	@scripts/kube.sh k9s

shell: ## subshell with the demo cluster's KUBECONFIG (use kubectl/helm/k9s directly)
	@scripts/kube.sh shell

kube-env: ## export line: eval "$$(make -s kube-env)"
	@scripts/kube.sh env

hooks: ## enable secret-scanning git hooks (gitleaks on commit and push)
	@git config core.hooksPath .githooks && echo "  ok git hooks active: .githooks (pre-commit, pre-push)"

secrets-scan: ## scan the entire git history and the working tree for secrets (gitleaks)
	@scripts/secrets-scan.sh

lint-language: ## list lines that look German (repository must be English)
	@scripts/lint-language.sh

test: ## shellcheck + unit tests (bats)
	@shellcheck scripts/*.sh providers/*.sh
	@bats tests
	@scripts/lint-language.sh

.PHONY: hooks secrets-scan lint-language doctor repair certs certs-status certs-autorenew certs-cleanup up down status login bootstrap smoke cf upstream help prereqs prereqs-check configure config-show dns dns-check dns-remove dns-public secrets-set-dns secrets-check kubectl k9s shell kube-env test
