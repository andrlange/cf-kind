setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/tls.sh
  source "$CFKD_ROOT/scripts/tls.sh"
  ca="$BATS_TEST_TMPDIR/ca"
  mkdir -p "$ca"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca/ca.key" -out "$ca/ca.crt" -days 30 -subj "/CN=test-ca" >/dev/null 2>&1
}

@test "issue_from_ca issues a certificate with all SANs, signed by the CA" {
  out="$BATS_TEST_TMPDIR/out"
  issue_from_ca "$ca/ca.crt" "$ca/ca.key" "*.sys.x.io *.app.x.io x.io" "$out"
  openssl verify -CAfile "$ca/ca.crt" "$out/fullchain.pem" | grep -q ': OK'
  san="$(openssl x509 -noout -text -in "$out/fullchain.pem" | grep -A1 'Subject Alternative Name' | tail -1)"
  [[ "$san" == *"DNS:*.sys.x.io"* ]] || false
  [[ "$san" == *"DNS:*.app.x.io"* ]] || false
  [[ "$san" == *"DNS:x.io"* ]] || false
  [ "$(stat -f %Lp "$out/privkey.pem")" = "600" ]
}

@test "gateway_cert_source: letsencrypt uses the lego storage, selfsigned the CA issuance" {
  printf 'DOMAIN="kind.cfapps.cool"\nTLS_MODE="letsencrypt"\nACME_EMAIL="a@cfapps.cool"\nACME_ENV="prod"\n' > "$CFKD_CONFIG"
  load_config
  [ "$(gateway_cert_source)" = "$CFKD_HOME/certs/prod/kind.cfapps.cool" ]
  printf 'DOMAIN="kind.cfapps.cool"\nTLS_MODE="selfsigned"\n' > "$CFKD_CONFIG"
  load_config
  [ "$(gateway_cert_source)" = "$CFKD_HOME/certs/selfsigned/kind.cfapps.cool" ]
}

@test "needs_public_tls only for a custom domain" {
  load_config
  ! needs_public_tls
  printf 'DOMAIN="kind.cfapps.cool"\n' > "$CFKD_CONFIG"
  load_config
  needs_public_tls
}
