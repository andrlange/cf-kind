# Guards the test suite itself.

@test "every [[ ]] assertion ends with '|| false' (bash 3.2 does not trigger set -e for a failing [[ ]])" {
  run grep -nE '^[[:space:]]+(!\s*)?\[\[.*\]\][[:space:]]*$' "$BATS_TEST_DIRNAME"/*.bats
  [ -z "$output" ] || { echo "$output"; false; }
}
