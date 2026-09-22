setup() {
  export CFKD_ROOT="$BATS_TEST_DIRNAME/.." CFKD_CONFIG="$BATS_TEST_TMPDIR/config.env" CFKD_HOME="$BATS_TEST_TMPDIR/home"
  # shellcheck source=../scripts/doctor.sh
  source "$CFKD_ROOT/scripts/doctor.sh"
}

@test "subnets_overlap detects overlapping and disjoint networks" {
  subnets_overlap 172.18.0.0/16 172.18.5.0/24
  subnets_overlap 10.0.0.0/8 10.213.0.0/16
  ! subnets_overlap 172.18.0.0/16 192.168.178.0/24
  ! subnets_overlap 10.213.0.0/16 10.214.0.0/16
}

@test "clock_drift returns the absolute difference in seconds" {
  [ "$(clock_drift 1000 1003)" = "3" ]
  [ "$(clock_drift 1003 1000)" = "3" ]
}

@test "cert_level: ok, warn below 21 days, fail below 7 days" {
  [ "$(cert_level 40)" = "ok" ]
  [ "$(cert_level 20)" = "warn" ]
  [ "$(cert_level 6)" = "fail" ]
}

@test "host_subnets extracts IPv4 networks from ifconfig output, ignoring loopback" {
  out=$'en0: flags=8863<UP>\n\tinet 192.168.178.23 netmask 0xffffff00 broadcast 192.168.178.255\nlo0: flags=8049\n\tinet 127.0.0.1 netmask 0xff000000'
  run host_subnets <<<"$out"
  [ "${lines[0]}" = "192.168.178.0/24" ]
  [ "${#lines[@]}" -eq 1 ]
}
