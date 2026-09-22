setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.."
  # shellcheck source=../scripts/lint-language.sh
  source "$CFKD_ROOT/scripts/lint-language.sh"
}

@test "german_lines flags umlauts and common German words" {
  printf 'echo "hello world"\n# prüft die Konfiguration\nlog_ok "Konfiguration gespeichert"\n' > "$BATS_TEST_TMPDIR/a.sh"  # lint-language: allow
  run german_lines "$BATS_TEST_TMPDIR/a.sh"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *":2:"* ]] || false
}

@test "german_lines passes English text, URLs and allowlisted names" {
  printf 'echo "check the configuration"\n# see https://example.org/über\nDNS name andreas-lange.de\n' > "$BATS_TEST_TMPDIR/b.sh"
  run german_lines "$BATS_TEST_TMPDIR/b.sh"
  [ -z "$output" ]
}

@test "german_lines ignores the bash helper 'die' and the English word 'die'" {
  printf 'die "unknown command" "usage: x"\n# the process may die here\n' > "$BATS_TEST_TMPDIR/c.sh"
  run german_lines "$BATS_TEST_TMPDIR/c.sh"
  [ -z "$output" ]
}

@test "german_lines skips lines marked 'lint-language: allow'" {
  printf 'x="für"  # lint-language: allow\n' > "$BATS_TEST_TMPDIR/d.sh"
  run german_lines "$BATS_TEST_TMPDIR/d.sh"
  [ -z "$output" ]
}
