setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/certs.sh
  source "$CFKD_ROOT/scripts/certs.sh"
}

# self-signed test certificate: make_cert FILE DAYS SAN…
make_cert() {
  local file="$1" days="$2"; shift 2
  local san="" d
  for d in "$@"; do san="${san:+$san,}DNS:$d"; done
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$file.key" -out "$file" \
    -days "$days" -subj "/CN=$1" -addext "subjectAltName=$san" >/dev/null 2>&1
}

@test "lego_domain_args emits one -d per SAN" {
  run lego_domain_args "*.sys.x.io sys.x.io"
  [ "$output" = "-d *.sys.x.io -d sys.x.io" ]
}

@test "acme_server knows staging and prod" {
  [ "$(acme_server staging)" = "https://acme-staging-v02.api.letsencrypt.org/directory" ]
  [ "$(acme_server prod)" = "https://acme-v02.api.letsencrypt.org/directory" ]
}

@test "cert_days_left reads the remaining validity" {
  make_cert "$BATS_TEST_TMPDIR/c.pem" 40 a.x.io
  days="$(cert_days_left "$BATS_TEST_TMPDIR/c.pem")"
  [ "$days" -ge 39 ] && [ "$days" -le 40 ]
}

@test "cert_covers_sans checks that all SANs are included" {
  make_cert "$BATS_TEST_TMPDIR/c.pem" 40 '*.sys.x.io' 'sys.x.io'
  cert_covers_sans "$BATS_TEST_TMPDIR/c.pem" "*.sys.x.io sys.x.io"
  ! cert_covers_sans "$BATS_TEST_TMPDIR/c.pem" "*.sys.x.io *.app.x.io"
}

@test "renewal_reason: missing, SANs changed, expiring soon, current" {
  f="$BATS_TEST_TMPDIR/c.pem"
  [ "$(renewal_reason "$f" "a.x.io" 30)" = "missing" ]
  make_cert "$f" 90 a.x.io
  [ "$(renewal_reason "$f" "a.x.io b.x.io" 30)" = "sans-changed" ]
  [ "$(renewal_reason "$f" "a.x.io" 30)" = "" ]
  make_cert "$f" 10 a.x.io
  [ "$(renewal_reason "$f" "a.x.io" 30)" = "expiring" ]
}

@test "cert_store is per ACME environment and domain under CFKD_HOME" {
  ACME_ENV=staging DOMAIN=kind.cfapps.cool run cert_store
  [ "$output" = "$CFKD_HOME/certs/staging/kind.cfapps.cool" ]
}

@test "install_issued_cert swaps atomically and keeps the old state on error" {
  store="$BATS_TEST_TMPDIR/store"
  mkdir -p "$store"; echo old > "$store/fullchain.pem"; echo oldkey > "$store/privkey.pem"
  new="$BATS_TEST_TMPDIR/new"; mkdir -p "$new"; echo new > "$new/fullchain.pem"
  run install_issued_cert "$new" "$store"
  [ "$status" -ne 0 ]
  [ "$(cat "$store/fullchain.pem")" = "old" ]
  echo newkey > "$new/privkey.pem"
  install_issued_cert "$new" "$store"
  [ "$(cat "$store/fullchain.pem")" = "new" ]
  [ "$(stat -f %Lp "$store/privkey.pem")" = "600" ]
}

@test "render_renew_plist: daily launchd job that runs make certs in the project" {
  run render_renew_plist /opt/homebrew/bin /repo /logs/renew.log
  [[ "$output" == *"<string>io.cf-kind-demo.certs-renew</string>"* ]]
  [[ "$output" == *"<string>make -C /repo certs</string>"* ]]
  [[ "$output" == *"<key>StartCalendarInterval</key>"* ]]
  [[ "$output" == *"<string>/logs/renew.log</string>"* ]]
  [[ "$output" == *"/opt/homebrew/bin"* ]]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/p.plist"
  plutil -lint "$BATS_TEST_TMPDIR/p.plist"
}

@test "stale_challenge_records selects only _acme-challenge TXT records below DOMAIN" {
  list=$'_acme-challenge.sys.kind.cfapps.cool.\tTXT\n_acme-challenge.kind.cfapps.cool.\tTXT\n*.sys.kind.cfapps.cool.\tA\n_acme-challenge.other.cfapps.cool.\tTXT\n_acme-challenge.kind.cfapps.cool.\tCNAME'
  run stale_challenge_records kind.cfapps.cool "$list"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "_acme-challenge.sys.kind.cfapps.cool." ]
  [ "${lines[1]}" = "_acme-challenge.kind.cfapps.cool." ]
}

@test "lego_propagation_args waits a fixed time instead of checking itself (networks with DNS interception)" {
  ACME_PROPAGATION_WAIT=90s run lego_propagation_args
  [ "$output" = "--dns.propagation.wait 90s" ]
}
