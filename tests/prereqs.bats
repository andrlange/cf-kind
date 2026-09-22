setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/prereqs.sh
  source "$CFKD_ROOT/scripts/prereqs.sh"
}

@test "port_in_use detects a busy port" {
  python3 -c 'import socket,time;s=socket.socket();s.bind(("127.0.0.1",38765));s.listen();time.sleep(5)' &
  pid=$!
  sleep 0.5
  port_in_use 38765
  kill "$pid"; wait "$pid" 2>/dev/null || true
}

@test "port_in_use reports a free port as free" {
  ! port_in_use 38766
}

@test "parse_docker_desktop_version reads the version number" {
  run parse_docker_desktop_version <<<"Docker Desktop 4.91.0 (239619)"
  [ "$output" = "4.91.0" ]
}

@test "parse_docker_desktop_version returns nothing for foreign output" {
  run parse_docker_desktop_version <<<"Docker version 29.8.0, build 88096ef"
  [ -z "$output" ]
}

@test "bytes_to_gib rounds down" {
  [ "$(bytes_to_gib 33596223488)" = "31" ]
  [ "$(bytes_to_gib 8589934592)" = "8" ]
}

@test "check counts ok, warn and fail" {
  check ok "a"
  check warn "b"
  check fail "c" "do something"
  [ "$N_OK" -eq 1 ]
  [ "$N_WARN" -eq 1 ]
  [ "$N_FAIL" -eq 1 ]
}


# brew stub: bundle check reports missing formulae (like Homebrew 7 with --no-upgrade)
stub_brew_missing() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/brew" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "Homebrew 7.0.6" ;;
  "bundle check")
    echo "brew bundle can't satisfy your Brewfile's dependencies."
    echo "→ Formula dnsmasq needs to be installed." >&2
    echo "→ Formula lego needs to be installed." >&2
    exit 1 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/brew"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "check_brew in check mode reports missing tools without aborting" {
  stub_brew_missing
  MODE=check
  run check_brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing tools: dnsmasq lego"* ]] || false
}

@test "missing_brew_formulae extracts the formula names" {
  run missing_brew_formulae <<<$'brew bundle can\'t satisfy\n→ Formula jq needs to be installed.\n→ Cask docker-desktop needs to be installed or updated.\nSatisfy …'
  [ "$output" = "jq docker-desktop" ]
}

@test "hooks_enabled is true only when core.hooksPath points to .githooks" {
  repo="$BATS_TEST_TMPDIR/r"
  git init -q "$repo"
  ! hooks_enabled "$repo"
  git -C "$repo" config core.hooksPath .githooks
  hooks_enabled "$repo"
}
