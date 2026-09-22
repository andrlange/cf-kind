setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/upstream.sh
  source "$CFKD_ROOT/scripts/upstream.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

make_repo() {
  repo="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$repo"
  printf 'line1\nline2\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m init
}

make_patch() { # make_patch DIR NAME NEWLINE2
  mkdir -p "$1"
  cat > "$1/$2" <<P
--- a/file.txt
+++ b/file.txt
@@ -1,2 +1,2 @@
 line1
-line2
+$3
P
}

@test "read_lock reads url and commit" {
  UPSTREAM_LOCK="$BATS_TEST_TMPDIR/lock"
  printf '# c\nurl=https://x/y.git\ncommit=abc123\n' > "$UPSTREAM_LOCK"
  [ "$(read_lock url)" = "https://x/y.git" ]
  [ "$(read_lock commit)" = "abc123" ]
}

@test "apply_patches applies patches once and is a no-op afterwards" {
  make_repo
  make_patch "$BATS_TEST_TMPDIR/patches" 01-x.patch changed
  PATCHES_DIR="$BATS_TEST_TMPDIR/patches" apply_patches "$repo"
  [ "$(sed -n 2p "$repo/file.txt")" = "changed" ]
  PATCHES_DIR="$BATS_TEST_TMPDIR/patches" run apply_patches "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already applied"* ]] || false
  [ "$(sed -n 2p "$repo/file.txt")" = "changed" ]
}

@test "apply_patches resets and reapplies when the patch set changed" {
  make_repo
  make_patch "$BATS_TEST_TMPDIR/patches" 01-x.patch changed
  PATCHES_DIR="$BATS_TEST_TMPDIR/patches" apply_patches "$repo"
  make_patch "$BATS_TEST_TMPDIR/patches" 01-x.patch other
  PATCHES_DIR="$BATS_TEST_TMPDIR/patches" apply_patches "$repo"
  [ "$(sed -n 2p "$repo/file.txt")" = "other" ]
}

@test "apply_patches without patches leaves the checkout clean" {
  make_repo
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  PATCHES_DIR="$BATS_TEST_TMPDIR/empty" apply_patches "$repo"
  [ -z "$(git -C "$repo" status --porcelain -- file.txt)" ]
}

@test "upstream_env sets KUBECONFIG and CF_HOME project-locally" {
  export KUBECONFIG="$HOME/.kube/config" CF_HOME="$HOME"
  upstream_env
  [ "$KUBECONFIG" = "$CFKD_HOME/kubeconfig" ]
  [ "$CF_HOME" = "$CFKD_HOME/cf" ]
}

@test "upstream_env puts upstream/bin on the PATH (tools such as yq/crane from the upstream pin)" {
  UPSTREAM_DIR="$BATS_TEST_TMPDIR/up"
  upstream_env
  [[ ":$PATH:" == *":$UPSTREAM_DIR/bin:"* ]] || false
}

@test "upstream_make installs the tools required by upstream scripts beforehand" {
  UPSTREAM_DIR="$BATS_TEST_TMPDIR/up"
  mkdir -p "$UPSTREAM_DIR/scripts"
  cat > "$UPSTREAM_DIR/scripts/tools.sh" <<'T'
tools::install::yq() { echo yq >> "$CALLS"; }
tools::install::crane() { echo crane >> "$CALLS"; }
tools::install::kubectl() { echo kubectl >> "$CALLS"; }
T
  printf 'noop:\n\t@true\n' > "$UPSTREAM_DIR/Makefile"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  upstream_make noop
  [ "$(sort "$CALLS" | tr '\n' ' ')" = "crane kubectl yq " ]
}

@test "upstream_env passes the domain to the upstream patch (split, custom domain → public-tls)" {
  printf 'DOMAIN="kind.cfapps.cool"\n' > "$CFKD_CONFIG"
  load_config
  upstream_env
  [ "$CF_BASE_DOMAIN" = "kind.cfapps.cool" ]
  [ "$CF_SYSTEM_DOMAIN" = "sys.kind.cfapps.cool" ]
  [ "$CF_APPS_DOMAIN" = "app.kind.cfapps.cool" ]
  [ "$CF_BLOBSTORE_DOMAIN" = "blobstore.sys.kind.cfapps.cool" ]
  [ "$CF_GATEWAY_TLS_SECRET" = "public-tls" ]
}

@test "upstream_env without a domain keeps the upstream certificate" {
  load_config
  upstream_env
  [ "$CF_BASE_DOMAIN" = "127-0-0-1.nip.io" ]
  [ "$CF_SYSTEM_DOMAIN" = "cf.127-0-0-1.nip.io" ]
  [ "$CF_GATEWAY_TLS_SECRET" = "all-in-one-tls" ]
}

@test "upstream_env exports the demo domain SANs for upstream's internal all-in-one certificate" {
  printf 'DOMAIN="kind.cfapps.cool"\n' > "$CFKD_CONFIG"
  load_config
  upstream_env
  [ "$CF_CERT_EXTRA_SANS" = "$CERT_SANS" ]
  [[ "$CF_CERT_EXTRA_SANS" == *"*.sys.kind.cfapps.cool"* ]] || false
}

@test "upstream_env adds no extra SANs without an own domain" {
  load_config
  upstream_env
  [ -z "$CF_CERT_EXTRA_SANS" ]
}
