# Brewfile — prerequisites for cf-kind-demo. `make prereqs` runs `brew bundle` with it.
tap "cloudfoundry/tap"

# install Docker Desktop only if it is not already (manually) installed
cask "docker-desktop" unless File.exist?("/Applications/Docker.app")

brew "cloudfoundry/tap/cf-cli@8"
brew "jq"
brew "dnsmasq"      # local resolver for the demo domains (chapter 10)
brew "crane"        # inspect images/manifests, airgap seeding
brew "kubectl"
brew "helm"
brew "lego"         # ACME client for Let's Encrypt wildcards via DNS-01 (chapter 9)
brew "mkcert"       # locally trusted CA for TLS_MODE=selfsigned
brew "gitleaks"     # blocks secrets in commits and pushes (.githooks)
brew "shellcheck"
brew "bats-core"
brew "k9s"

# only for K8S_PROVIDER=k3d
brew "k3d" if ENV["CFKD_WITH_K3D"] == "1"
