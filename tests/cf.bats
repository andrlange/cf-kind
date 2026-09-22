setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/cf.sh
  source "$CFKD_ROOT/scripts/cf.sh"
}

@test "cf_api_url follows the system domain" {
  SYSTEM_DOMAIN="cf.127-0-0-1.nip.io" run cf_api_url
  [ "$output" = "https://api.cf.127-0-0-1.nip.io" ]
  SYSTEM_DOMAIN="sys.kind.cfapps.cool" run cf_api_url
  [ "$output" = "https://api.sys.kind.cfapps.cool" ]
}

@test "cf wrapper never uses ~/.cf" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho "CF_HOME=$CF_HOME ARGS=$*"\n' > "$BATS_TEST_TMPDIR/bin/cf"
  chmod +x "$BATS_TEST_TMPDIR/bin/cf"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" CF_HOME="$HOME" run "$CFKD_ROOT/scripts/cf.sh" cf apps
  [ "$output" = "CF_HOME=$CFKD_HOME/cf ARGS=apps" ]
}

@test "smoke_url builds the route of the sample app" {
  APPS_DOMAIN="apps.127-0-0-1.nip.io" run smoke_url hello-js
  [ "$output" = "https://hello-js.apps.127-0-0-1.nip.io" ]
}

@test "cf_ssl_flag: only a Let's Encrypt prod certificate omits --skip-ssl-validation" {
  DOMAIN=kind.cfapps.cool TLS_MODE=letsencrypt ACME_ENV=prod run cf_ssl_flag
  [ "$output" = "" ]
  DOMAIN=kind.cfapps.cool TLS_MODE=letsencrypt ACME_ENV=staging run cf_ssl_flag
  [ "$output" = "--skip-ssl-validation" ]
  DOMAIN=127-0-0-1.nip.io TLS_MODE=selfsigned ACME_ENV=prod run cf_ssl_flag
  [ "$output" = "--skip-ssl-validation" ]
}
