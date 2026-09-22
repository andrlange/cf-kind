setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/secrets.sh
  source "$CFKD_ROOT/scripts/secrets.sh"
  SA="$BATS_TEST_TMPDIR/sa.json"
  echo '{"type":"service_account","project_id":"p","client_email":"a@p.iam.gserviceaccount.com","private_key":"x"}' > "$SA"
}

@test "validate_sa_json accepts service account JSON" {
  validate_sa_json "$SA"
}

@test "validate_sa_json rejects other credential types and broken JSON" {
  f="$BATS_TEST_TMPDIR/x.json"
  echo '{"type":"authorized_user","client_id":"x"}' > "$f"
  ! validate_sa_json "$f"
  echo 'not json' > "$f"
  ! validate_sa_json "$f"
  ! validate_sa_json "$BATS_TEST_TMPDIR/does-not-exist.json"
}

@test "dns_credentials_source recognizes keychain and file variants" {
  ACME_DNS_CREDENTIALS="keychain:foo" run dns_credentials_source
  [ "$output" = "keychain:foo" ]
  ACME_DNS_CREDENTIALS="~/x.json" run dns_credentials_source
  [ "$output" = "$HOME/x.json" ]
}

@test "file variant: check-dns requires permissions 0600" {
  chmod 644 "$SA"
  ACME_DNS_CREDENTIALS="$SA" run check_dns
  [ "$status" -ne 0 ]
  [[ "$output" == *"0600"* ]] || false
  chmod 600 "$SA"
  ACME_DNS_CREDENTIALS="$SA" run check_dns
  [ "$status" -eq 0 ]
}

@test "keychain roundtrip: set, read, delete" {
  [ "${CFKD_KEYCHAIN_TESTS:-0}" = 1 ] || skip "only with CFKD_KEYCHAIN_TESTS=1 (writes to the login keychain)"
  export ACME_DNS_CREDENTIALS="keychain:cf-kind-demo-test-$$"
  set_dns "$SA"
  [ "$(get_dns_credentials)" = "$(cat "$SA")" ]
  security delete-generic-password -s "cf-kind-demo-test-$$" >/dev/null
}

@test "dns_credentials_source resolves relative paths against the project" {
  ACME_DNS_CREDENTIALS=".secrets/gcp.json" run dns_credentials_source
  [ "$output" = "$CFKD_ROOT/.secrets/gcp.json" ]
  ACME_DNS_CREDENTIALS="/abs/gcp.json" run dns_credentials_source
  [ "$output" = "/abs/gcp.json" ]
}
