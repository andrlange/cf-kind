setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/dns.sh
  source "$CFKD_ROOT/scripts/dns.sh"
}

@test "dnsmasq.conf: loopback only, own port, one address line per domain, no upstream" {
  run render_dnsmasq_conf active kind.cfapps.cool 127-0-0-1.nip.io
  [[ "$output" == *"port=53535"* ]] || false
  [[ "$output" == *"listen-address=127.0.0.1"* ]] || false
  [[ "$output" == *"bind-interfaces"* ]] || false
  [[ "$output" == *"no-resolv"* ]] || false
  [[ "$output" == *"address=/kind.cfapps.cool/127.0.0.1"* ]] || false
  [[ "$output" == *"address=/127-0-0-1.nip.io/127.0.0.1"* ]] || false
}

@test "resolver file carries marker, nameserver and port" {
  run render_resolver
  [ "${lines[0]}" = "# managed by cf-kind-demo" ]
  [[ "$output" == *"nameserver 127.0.0.1"* ]] || false
  [[ "$output" == *"port 53535"* ]] || false
}

@test "launchd plist starts dnsmasq in the foreground with our config and is valid" {
  run render_launchd_plist /opt/homebrew/sbin/dnsmasq /tmp/x.conf
  [[ "$output" == *"<string>io.cf-kind-demo.dnsmasq</string>"* ]] || false
  [[ "$output" == *"<string>--keep-in-foreground</string>"* ]] || false
  [[ "$output" == *"<string>--conf-file=/tmp/x.conf</string>"* ]] || false
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/p.plist"
  plutil -lint "$BATS_TEST_TMPDIR/p.plist"
}

@test "is_managed_resolver distinguishes own and foreign files" {
  f="$BATS_TEST_TMPDIR/r"
  render_resolver > "$f"
  is_managed_resolver "$f"
  echo "nameserver 10.0.0.1" > "$f"
  ! is_managed_resolver "$f"
}

@test "resolver_plan: a foreign file is a conflict, an identical own file is skipped" {
  dir="$BATS_TEST_TMPDIR/resolver"
  mkdir -p "$dir"
  echo "nameserver 10.0.0.1" > "$dir/foreign.example"
  render_resolver > "$dir/kind.cfapps.cool"
  RESOLVER_DIR="$dir" run resolver_plan kind.cfapps.cool foreign.example 127-0-0-1.nip.io
  [ "${lines[0]}" = "skip kind.cfapps.cool" ]
  [ "${lines[1]}" = "conflict foreign.example" ]
  [ "${lines[2]}" = "write 127-0-0-1.nip.io" ]
}

@test "dnsmasq runs as user on port 53535 and answers demo domains" {
  bin="$(dnsmasq_bin 2>/dev/null)" || skip "dnsmasq not installed"
  conf="$BATS_TEST_TMPDIR/d.conf"
  render_dnsmasq_conf active kind.cfapps.cool | sed 's/port=53535/port=53599/' > "$conf"
  "$bin" --keep-in-foreground --conf-file="$conf" &
  pid=$!
  sleep 0.5
  run dig +short +time=2 @127.0.0.1 -p 53599 api.sys.kind.cfapps.cool
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [ "$output" = "127.0.0.1" ]
}

@test "public_dns_records: one A record to 127.0.0.1 per certificate name (split)" {
  run public_dns_records "*.sys.kind.cfapps.cool *.app.kind.cfapps.cool *.blobstore.sys.kind.cfapps.cool *.kind.cfapps.cool kind.cfapps.cool"
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]}" = "*.sys.kind.cfapps.cool." ]
  [ "${lines[4]}" = "kind.cfapps.cool." ]
}

@test "zone_for_domain finds the matching zone in a list" {
  run zone_for_domain kind.cfapps.cool $'andreas-lange andreas-lange.eu.\nexample-zone cfapps.cool.\nother other.de.'
  [ "$output" = "example-zone" ]
}

@test "passthrough mode forwards to the current network's DNS instead of answering 127.0.0.1" {
  run render_dnsmasq_conf passthrough kind.cfapps.cool 127-0-0-1.nip.io
  [[ "$output" == *"resolv-file=/etc/resolv.conf"* ]] || false
  [[ "$output" != *"address=/"* ]] || false
  [[ "$output" != *"no-resolv"* ]] || false
  [[ "$output" == *"listen-address=127.0.0.1"* ]] || false
}

@test "render_dnsmasq_conf rejects unknown modes" {
  run render_dnsmasq_conf sideways kind.cfapps.cool
  [ "$status" -ne 0 ]
}

@test "dns_mode_of reads the mode from a generated config" {
  f="$BATS_TEST_TMPDIR/d.conf"
  render_dnsmasq_conf active kind.cfapps.cool > "$f"
  [ "$(dns_mode_of "$f")" = "active" ]
  render_dnsmasq_conf passthrough kind.cfapps.cool > "$f"
  [ "$(dns_mode_of "$f")" = "passthrough" ]
  [ "$(dns_mode_of "$BATS_TEST_TMPDIR/missing")" = "absent" ]
}

@test "dnsmasq in passthrough mode resolves real public names" {
  bin="$(dnsmasq_bin 2>/dev/null)" || skip "dnsmasq not installed"
  dig +short +time=2 +tries=1 example.com >/dev/null 2>&1 || skip "no network"
  conf="$BATS_TEST_TMPDIR/p.conf"
  render_dnsmasq_conf passthrough kind.cfapps.cool | sed 's/port=53535/port=53598/' > "$conf"
  "$bin" --keep-in-foreground --conf-file="$conf" &
  pid=$!
  sleep 0.5
  run dig +short +time=3 @127.0.0.1 -p 53598 example.com
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [ -n "$output" ]
  [[ "$output" != "127.0.0.1" ]] || false
}

@test "only_loopback: public records are removed only if they point exclusively to 127.0.0.1" {
  only_loopback "127.0.0.1"
  ! only_loopback "203.0.113.7"
  ! only_loopback "127.0.0.1;203.0.113.7"
  ! only_loopback ""
}

@test "render_sudoers allows exactly the two DNS cache flush commands without a password" {
  run render_sudoers alice
  [ "${lines[0]}" = "# managed by cf-kind-demo — lets 'make up/down' flush the macOS DNS cache without a password" ]
  [ "${lines[1]}" = "alice ALL=(root) NOPASSWD: /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder" ]
  [ "${#lines[@]}" -eq 2 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/sudoers"
  /usr/sbin/visudo -cf "$BATS_TEST_TMPDIR/sudoers" >/dev/null
}
