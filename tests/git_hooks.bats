setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.."
  command -v gitleaks >/dev/null || skip "gitleaks not installed"
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config core.hooksPath "$CFKD_ROOT/.githooks"
}

@test "pre-commit hook blocks a staged private key" {
  openssl genrsa 2048 2>/dev/null > "$repo/leak.pem"   # throwaway key, generated at test time
  git -C "$repo" add leak.pem
  run git -C "$repo" commit -m leak
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$repo" log --oneline 2>/dev/null)" ]
}

@test "pre-commit hook lets harmless changes through" {
  echo "hello" > "$repo/readme.txt"
  git -C "$repo" add readme.txt
  git -C "$repo" commit -q -m ok
  [ "$(git -C "$repo" log --oneline | wc -l | tr -d ' ')" = "1" ]
}

@test "pre-push hook blocks commits with secrets even if pre-commit was bypassed" {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git -C "$repo" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  openssl genrsa 2048 2>/dev/null > "$repo/leak.pem"
  git -C "$repo" add leak.pem
  git -C "$repo" commit -q --no-verify -m leak
  run git -C "$repo" push -q origin main
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$BATS_TEST_TMPDIR/remote.git" log --oneline 2>/dev/null)" ]
}

@test "pre-push hook lets clean commits through" {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git -C "$repo" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  echo ok > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -q -m ok
  git -C "$repo" push -q origin main
  [ "$(git -C "$BATS_TEST_TMPDIR/remote.git" log --oneline | wc -l | tr -d ' ')" = "1" ]
}
