setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/ui.sh
  source "$CFKD_ROOT/scripts/ui.sh"
}

@test "stratos_url uses the system domain" {
  SYSTEM_DOMAIN=sys.kind.cfapps.cool run stratos_url
  [ "$output" = "https://ui.sys.kind.cfapps.cool:5443" ]
  SYSTEM_DOMAIN=cf.127-0-0-1.nip.io run stratos_url
  [ "$output" = "https://ui.cf.127-0-0-1.nip.io:5443" ]
}

@test "stratos_asset and download URL are pinned to the version" {
  [ "$(stratos_asset)" = "stratos-v${STRATOS_VERSION}-darwin-arm64.tar.gz" ]
  [ "$(stratos_download_url)" = "https://github.com/cloudfoundry/stratos/releases/download/v${STRATOS_VERSION}/stratos-v${STRATOS_VERSION}-darwin-arm64.tar.gz" ]
  [[ "$STRATOS_SHA256" =~ ^[0-9a-f]{64}$ ]] || false
}

@test "render_stratos_config: local admin, loopback listener, cert paths, no Stratos auto-registration" {
  run render_stratos_config /c/fullchain.pem /c/privkey.pem /ui false "sesssecret" "ENCKEY" "adminpw" "https://ui.sys.x.io:5443"
  [[ "$output" == *"CONSOLE_PROXY_TLS_ADDRESS=127.0.0.1:5443"* ]] || false
  [[ "$output" == *"CONSOLE_PROXY_CERT_PATH=/c/fullchain.pem"* ]] || false
  [[ "$output" == *"CONSOLE_PROXY_CERT_KEY_PATH=/c/privkey.pem"* ]] || false
  [[ "$output" == *"UI_PATH=/ui"* ]] || false
  [[ "$output" == *"SKIP_SSL_VALIDATION=false"* ]] || false
  [[ "$output" == *"AUTH_ENDPOINT_TYPE=local"* ]] || false
  [[ "$output" == *"LOCAL_USER_PASSWORD=adminpw"* ]] || false
  [[ "$output" == *"ENCRYPTION_KEY=ENCKEY"* ]] || false
  [[ "$output" == *"ALLOWED_ORIGINS=https://ui.sys.x.io:5443"* ]] || false
  [[ "$output" != *"AUTO_REG_CF_URL"* ]] || false
}

@test "render_stratos_plist runs jetstream in the run directory and is valid" {
  run render_stratos_plist /opt/stratos/bin/jetstream /run/dir /logs/ui.log
  [[ "$output" == *"<string>io.cf-kind-demo.stratos</string>"* ]] || false
  [[ "$output" == *"<key>WorkingDirectory</key>"* ]] || false
  [[ "$output" == *"<string>/run/dir</string>"* ]] || false
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/p.plist"
  plutil -lint "$BATS_TEST_TMPDIR/p.plist"
}

@test "stratos_skip_ssl: only a Let's Encrypt prod certificate is verified strictly" {
  DOMAIN=kind.cfapps.cool TLS_MODE=letsencrypt ACME_ENV=prod run stratos_skip_ssl
  [ "$output" = "false" ]
  DOMAIN=kind.cfapps.cool TLS_MODE=letsencrypt ACME_ENV=staging run stratos_skip_ssl
  [ "$output" = "true" ]
  DOMAIN=127-0-0-1.nip.io TLS_MODE=selfsigned ACME_ENV=prod run stratos_skip_ssl
  [ "$output" = "true" ]
}

@test "xsrf_from_headers extracts the token case-insensitively" {
  run xsrf_from_headers <<<$'HTTP/2 200 \r\nX-XSRF-Token: abc123\r\nx-frame-options: DENY\r\n'
  [ "$output" = "abc123" ]
}

@test "endpoint_guid_by_name finds a registered endpoint" {
  json='[{"guid":"g1","name":"other","cnsi_type":"cf"},{"guid":"g2","name":"cf-kind-demo","cnsi_type":"cf"}]'
  [ "$(endpoint_guid_by_name cf-kind-demo <<<"$json")" = "g2" ]
  [ -z "$(endpoint_guid_by_name missing <<<"$json")" ]
}

@test "ensure_stratos_secrets creates stable secrets once (0600) and reuses them" {
  ensure_stratos_secrets
  first="$(cat "$STRATOS_HOME/secrets.env")"
  [ "$(stat -f %Lp "$STRATOS_HOME/secrets.env")" = "600" ]
  ensure_stratos_secrets
  [ "$(cat "$STRATOS_HOME/secrets.env")" = "$first" ]
  grep -qE '^ENCRYPTION_KEY=[0-9A-F]{64}$' "$STRATOS_HOME/secrets.env"
}
