setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/lib.sh
  source "$CFKD_ROOT/scripts/lib.sh"
}

@test "version_ge compares numerically" {
  version_ge 4.91.0 4.38
  version_ge 4.38 4.38
  ! version_ge 4.9 4.38
  version_ge 8.18.0+fad4bcb.2026-03-04 8
}

@test "without DOMAIN the upstream nip.io scheme applies" {
  load_config
  [ "$DOMAIN" = "127-0-0-1.nip.io" ]
  [ "$SYSTEM_DOMAIN" = "cf.127-0-0-1.nip.io" ]
  [ "$APPS_DOMAIN" = "apps.127-0-0-1.nip.io" ]
  [ "$RESOLVER_DOMAINS" = "127-0-0-1.nip.io" ]
}

@test "split layout derives sys/app" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  load_config
  [ "$SYSTEM_DOMAIN" = "sys.kind.cfapps.cool" ]
  [ "$APPS_DOMAIN" = "app.kind.cfapps.cool" ]
  [ "$BLOBSTORE_DOMAIN" = "blobstore.sys.kind.cfapps.cool" ]
  [ "$CERT_SANS" = "*.sys.kind.cfapps.cool *.app.kind.cfapps.cool *.blobstore.sys.kind.cfapps.cool *.kind.cfapps.cool kind.cfapps.cool" ]
  [ "$RESOLVER_DOMAINS" = "kind.cfapps.cool 127-0-0-1.nip.io" ]
}

@test "flat layout uses the base for system and apps" {
  printf 'DOMAIN="kind.cfapps.cool"\nDOMAIN_LAYOUT="flat"\n' > "$CFKD_CONFIG"
  load_config
  [ "$SYSTEM_DOMAIN" = "kind.cfapps.cool" ]
  [ "$APPS_DOMAIN" = "kind.cfapps.cool" ]
  [ "$CERT_SANS" = "*.kind.cfapps.cool kind.cfapps.cool *.blobstore.kind.cfapps.cool" ]
}

@test "environment variables override config.env" {
  echo 'ACME_ENV="staging"' > "$CFKD_CONFIG"
  export ACME_ENV=prod
  load_config
  [ "$ACME_ENV" = "prod" ]
}

@test "validate_config: letsencrypt requires the domain to be inside the zone" {
  printf 'TLS_MODE="letsencrypt"\nDOMAIN="kind.example.org"\nACME_EMAIL="a@b.c"\n' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not inside DNS_ZONE"* ]] || false
}

@test "validate_config: letsencrypt without a domain is invalid" {
  echo 'TLS_MODE="letsencrypt"' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"DOMAIN"* ]] || false
}

@test "validate_config: valid letsencrypt configuration" {
  printf 'TLS_MODE="letsencrypt"\nDOMAIN="kind.cfapps.cool"\nACME_EMAIL="admin@cfapps.cool"\nGCP_PROJECT="example-project"\n' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -eq 0 ]
}

@test "validate_config: defaults are valid" {
  load_config
  run validate_config
  [ "$status" -eq 0 ]
}

@test "validate_config: unknown provider and layout" {
  printf 'K8S_PROVIDER="minikube"\nDOMAIN="x.cfapps.cool"\nDOMAIN_LAYOUT="diagonal"\n' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"K8S_PROVIDER"* ]] || false
  [[ "$output" == *"DOMAIN_LAYOUT"* ]] || false
}

# Let's Encrypt rejects names already covered by a wildcard in the same request ("redundant with a wildcard domain")
assert_no_redundant_sans() {
  local s w
  for s in $CERT_SANS; do
    [[ "$s" == \** ]] && continue
    for w in $CERT_SANS; do
      [[ "$w" == \** ]] || continue
      local base="${w#\*.}"
      if [[ "$s" == *".$base" && "${s%".$base"}" != *.* ]]; then echo "redundant: $s (covered by $w)"; return 1; fi
    done
  done
}

@test "CERT_SANS contain no names covered by wildcards (split and flat)" {
  set -f
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  load_config
  assert_no_redundant_sans
  printf 'DOMAIN="kind.cfapps.cool"\nDOMAIN_LAYOUT="flat"\n' > "$CFKD_CONFIG"
  load_config
  assert_no_redundant_sans
}

@test "load_config twice in the same process picks up a changed config.env" {
  echo 'TLS_MODE="letsencrypt"' > "$CFKD_CONFIG"
  load_config
  echo 'TLS_MODE="selfsigned"' > "$CFKD_CONFIG"
  load_config
  [ "$TLS_MODE" = "selfsigned" ]
}

@test "real environment overrides also apply on the second load_config" {
  echo 'ACME_ENV="staging"' > "$CFKD_CONFIG"
  export ACME_ENV=prod
  load_config
  load_config
  [ "$ACME_ENV" = "prod" ]
}

@test "validate_config: KIND_SUBNET must be an IPv4 CIDR" {
  echo 'KIND_SUBNET="not-a-cidr"' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"KIND_SUBNET"* ]] || false
}

@test "validate_config: letsencrypt with gcloud requires GCP_PROJECT" {
  printf 'TLS_MODE="letsencrypt"\nDOMAIN="kind.cfapps.cool"\nACME_EMAIL="a@cfapps.cool"\nGCP_PROJECT=""\n' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"GCP_PROJECT"* ]] || false
}

@test "validate_config: docker-desktop is rejected with the reason (needs a global ~/.kube/config)" {
  echo 'K8S_PROVIDER="docker-desktop"' > "$CFKD_CONFIG"
  load_config
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"global ~/.kube/config"* ]] || false
}

@test "the default provider is kind" {
  load_config
  [ "$K8S_PROVIDER" = "kind" ]
}
