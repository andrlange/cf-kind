setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/configure.sh
  source "$CFKD_ROOT/scripts/configure.sh"
}

@test "set_config_value replaces and appends" {
  printf 'A="1"\nB="2"\n' > "$CFKD_CONFIG"
  set_config_value "$CFKD_CONFIG" B 3
  set_config_value "$CFKD_CONFIG" C 4
  [ "$(cat "$CFKD_CONFIG")" = $'A="1"\nB="3"\nC="4"' ]
}

@test "set_config_value creates the file" {
  set_config_value "$CFKD_CONFIG" DOMAIN kind.cfapps.cool
  [ "$(cat "$CFKD_CONFIG")" = 'DOMAIN="kind.cfapps.cool"' ]
}

@test "configure writes valid values" {
  run "$CFKD_ROOT/scripts/configure.sh" TLS_MODE=letsencrypt DOMAIN=kind.cfapps.cool ACME_EMAIL=admin@cfapps.cool GCP_PROJECT=example-project
  [ "$status" -eq 0 ]
  grep -q '^DOMAIN="kind.cfapps.cool"$' "$CFKD_CONFIG"
  grep -q '^TLS_MODE="letsencrypt"$' "$CFKD_CONFIG"
}

@test "configure discards invalid values and leaves the file unchanged" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  run "$CFKD_ROOT/scripts/configure.sh" DOMAIN_LAYOUT=diagonal
  [ "$status" -ne 0 ]
  [[ "$output" == *"DOMAIN_LAYOUT"* ]] || false
  [ "$(cat "$CFKD_CONFIG")" = 'DOMAIN="kind.cfapps.cool"' ]
}

@test "configure rejects unknown keys" {
  run "$CFKD_ROOT/scripts/configure.sh" FOO=bar
  [ "$status" -ne 0 ]
  [[ "$output" == *"FOO"* ]] || false
}

@test "configure rejects special characters in values" {
  run "$CFKD_ROOT/scripts/configure.sh" 'DOMAIN=a$(id).cfapps.cool'
  [ "$status" -ne 0 ]
  [ ! -f "$CFKD_CONFIG" ]
}

@test "configure accepts empty values (reset DOMAIN)" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  run "$CFKD_ROOT/scripts/configure.sh" DOMAIN=
  [ "$status" -eq 0 ]
  grep -q '^DOMAIN=""$' "$CFKD_CONFIG"
}

@test "--show shows derived domains" {
  echo 'DOMAIN="kind.cfapps.cool"' > "$CFKD_CONFIG"
  run "$CFKD_ROOT/scripts/configure.sh" --show
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYSTEM_DOMAIN"*"sys.kind.cfapps.cool"* ]] || false
  [[ "$output" == *"APPS_DOMAIN"*"app.kind.cfapps.cool"* ]] || false
}

@test "without arguments and without a TTY configure aborts with a hint" {
  run "$CFKD_ROOT/scripts/configure.sh" < /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"KEY=VALUE"* ]] || false
}
