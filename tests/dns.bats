setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/dns.sh
  source "$CFKD_ROOT/scripts/dns.sh"
}

@test "dnsmasq.conf: loopback only, own port, one address line per domain, no upstream" {
  run render_dnsmasq_conf kind.cfapps.cool 127-0-0-1.nip.io
  [[ "$output" == *"port=53535"* ]]
  [[ "$output" == *"listen-address=127.0.0.1"* ]]
  [[ "$output" == *"bind-interfaces"* ]]
  [[ "$output" == *"no-resolv"* ]]
  [[ "$output" == *"address=/kind.cfapps.cool/127.0.0.1"* ]]
  [[ "$output" == *"address=/127-0-0-1.nip.io/127.0.0.1"* ]]
}

@test "resolver file carries marker, nameserver and port" {
  run render_resolver
  [ "${lines[0]}" = "# managed by cf-kind-demo" ]
  [[ "$output" == *"nameserver 127.0.0.1"* ]]
  [[ "$output" == *"port 53535"* ]]
}

@test "launchd plist starts dnsmasq in the foreground with our config and is valid" {
  run render_launchd_plist /opt/homebrew/sbin/dnsmasq /tmp/x.conf
  [[ "$output" == *"<string>io.cf-kind-demo.dnsmasq</string>"* ]]
  [[ "$output" == *"<string>--keep-in-foreground</string>"* ]]
  [[ "$output" == *"<string>--conf-file=/tmp/x.conf</string>"* ]]
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
  render_dnsmasq_conf kind.cfapps.cool | sed 's/port=53535/port=53599/' > "$conf"
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
