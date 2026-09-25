#!/usr/bin/env bash
# Behavior tests for the settings inspection and scrub boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secrets)
TOOL="$ROOT/bin/fm-secrets.sh"
ENV_FILE="$TMP_ROOT/settings.env"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

FAKE_URL_PASSWORD=fake_url_password_20260924
FAKE_QUOTED=fake_quoted_value_20260924
FAKE_MULTI_A=fake_multiline_first_20260924
FAKE_MULTI_B=fake_multiline_second_20260924
FAKE_NON_INJECTED=fake_non_injected_value_20260924
FAKE_PROCESS=fake_process_value_20260924
FAKE_INLINE=fake_inline_value_20260924
FAKE_PIN=12345
FAKE_AMBIENT_KEY=fake_ambient_typesafe_key_20260924

printf '%s\n' \
  '# synthetic settings - never real credentials' \
  "   export INDENTED_URL = \"postgres://fake_user:${FAKE_URL_PASSWORD}@fake.example/db\" # trailing comment" \
  "QUOTED_VALUE='${FAKE_QUOTED}'" \
  "MULTI_VALUE=\"${FAKE_MULTI_A}" \
  'LOOKS_LIKE_A_NAME=still_part_of_the_value' \
  "${FAKE_MULTI_B}\"" \
  "URL_PASSWORD=${FAKE_URL_PASSWORD}" \
  "NON_INJECTED_VALUE=${FAKE_NON_INJECTED}" \
  "PIN=${FAKE_PIN}" \
  'TOKEN=' \
  'SHORT_VALUE=abc' > "$ENV_FILE"

assert_no_fake_secret() {
  local output=$1 context=$2 marker
  for marker in \
    "$FAKE_URL_PASSWORD" "$FAKE_QUOTED" "$FAKE_MULTI_A" "$FAKE_MULTI_B" \
    "$FAKE_NON_INJECTED" "$FAKE_PROCESS" "$FAKE_INLINE" "$FAKE_PIN" \
    "$FAKE_AMBIENT_KEY"; do
    assert_not_contains "$output" "$marker" "$context leaked a synthetic secret byte sequence"
  done
}

test_names_and_has_never_print_values() {
  local names has expected
  names=$($TOOL names "$ENV_FILE" 2>&1) || fail "names failed"
  expected=$(printf '%s\n' INDENTED_URL QUOTED_VALUE MULTI_VALUE URL_PASSWORD NON_INJECTED_VALUE PIN TOKEN SHORT_VALUE)
  [ "$names" = "$expected" ] || fail "names did not parse supported env syntax: $names"
  assert_no_fake_secret "$names" "names"
  assert_not_contains "$names" 'LOOKS_LIKE_A_NAME' \
    "names treated a quoted multiline value as a new assignment"

  has=$($TOOL has "$ENV_FILE" INDENTED_URL MULTI_VALUE ABSENT_SETTING 2>&1) || fail "has failed"
  expected=$(printf '%s\n' 'INDENTED_URL=yes' 'MULTI_VALUE=yes' 'ABSENT_SETTING=no')
  [ "$has" = "$expected" ] || fail "has returned unexpected booleans: $has"
  assert_no_fake_secret "$has" "has"
  pass "fm-secrets: names and has expose names and booleans only"
}

test_run_scrubs_all_file_values_and_preserves_status() {
  local output rc
  # shellcheck disable=SC2016 # The child expands only its deliberately injected environment.
  output=$(SHORT_VALUE=ambient-value $TOOL run "$ENV_FILE" \
    --only INDENTED_URL,QUOTED_VALUE,MULTI_VALUE,URL_PASSWORD,PIN -- \
    sh -c '
      printf "%s\n" "$QUOTED_VALUE"
      printf "%s\n" "$MULTI_VALUE" >&2
      printf "postgres://another-user:%s@another.example/db\n" "$URL_PASSWORD"
      printf "%s\n" "$INDENTED_URL"
      printf "%s\n" "$1"
      printf "not-selected=%s\n" "${SHORT_VALUE-unset}"
      printf "pin=%s\n" "$PIN"
      exit 37
    ' -- "$FAKE_NON_INJECTED" 2>&1)
  rc=$?
  expect_code 37 "$rc" "run must preserve the child exit status"
  assert_no_fake_secret "$output" "run"
  assert_contains "$output" '<redacted:QUOTED_VALUE>' "run did not scrub an injected quoted value"
  assert_contains "$output" '<redacted:MULTI_VALUE>' "run did not scrub an injected multiline value"
  assert_contains "$output" '<redacted:URL_PASSWORD>' "run did not scrub a password in URL userinfo"
  assert_contains "$output" '<redacted:NON_INJECTED_VALUE>' \
    "run did not scrub a file value that was outside --only"
  assert_contains "$output" 'not-selected=unset' "run injected a file setting outside --only"
  assert_contains "$output" '<redacted:PIN>' "run did not scrub a short secret-bearing value"
  pass "fm-secrets: run scrubs stdout and stderr and preserves child status"
}

test_run_excludes_and_scrubs_ambient_secret_settings() {
  local output
  # shellcheck disable=SC2016 # The child expands only its deliberately injected environment.
  output=$(TYPESAFE_API_KEY="$FAKE_AMBIENT_KEY" $TOOL run "$ENV_FILE" --only PIN -- \
    sh -c 'printf "ambient=%s\n" "${TYPESAFE_API_KEY-unset}"; printf "pin=%s\n" "$PIN"' 2>&1) \
    || fail "run failed while excluding an ambient secret setting"
  assert_no_fake_secret "$output" "run ambient settings"
  assert_contains "$output" 'ambient=unset' "run inherited an ambient secret setting"
  assert_contains "$output" '<redacted:PIN>' "run did not scrub the requested short PIN"
  pass "fm-secrets: run excludes ambient secrets and scrubs short secret names"
}

test_run_ignores_empty_secret_values() {
  local output
  output=$($TOOL run "$ENV_FILE" --only TOKEN -- printf x 2>&1) \
    || fail "run failed with an empty secret setting"
  [ "$output" = x ] || fail "run let an empty secret setting corrupt command output: $output"
  pass "fm-secrets: empty secret settings do not corrupt output"
}

test_run_scrubs_empty_username_url_passwords() {
  local env_file output
  env_file="$TMP_ROOT/empty-username.env"
  printf '%s\n' 'DATABASE_URL=postgres://:12345@db/x' > "$env_file"
  output=$($TOOL run "$env_file" --only DATABASE_URL -- \
    sh -c 'password=${DATABASE_URL#*://:}; printf "%s\n" "${password%@*}"' 2>&1) \
    || fail "run failed with an empty URL username"
  assert_not_contains "$output" '12345' "run leaked an empty-username URL password"
  assert_contains "$output" '<redacted:DATABASE_URL>' \
    "run did not scrub an empty-username URL password"
  pass "fm-secrets: run scrubs empty-username URL passwords"
}

test_run_scrubs_url_decoded_passwords() {
  local env_file output
  env_file="$TMP_ROOT/encoded-password.env"
  printf '%s\n' 'DATABASE_URL=postgres://user:a%20b@db/x' > "$env_file"
  output=$($TOOL run "$env_file" --only DATABASE_URL -- \
    python3 -c 'from os import environ; from urllib.parse import unquote; print(unquote(environ["DATABASE_URL"].split("@", 1)[0].rsplit(":", 1)[1]))' 2>&1) \
    || fail "run failed with a percent-encoded URL password"
  assert_not_contains "$output" 'a b' "run leaked a decoded URL password"
  assert_contains "$output" '<redacted:DATABASE_URL>' \
    "run did not scrub a decoded URL password"
  pass "fm-secrets: run scrubs decoded URL passwords"
}

test_service_has_reads_process_environment_without_values() {
  local service_pid output expected
  env FM_FAKE_PROCESS_SETTING="$FAKE_PROCESS" sleep 30 &
  service_pid=$!
  trap 'kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fm_test_cleanup' EXIT

  # shellcheck disable=SC2016 # The generated stub expands this at execution time.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *--property=MainPID*) printf "%s\n" "${FM_TEST_SERVICE_PID:?}" ;;' \
    '  *) exit 64 ;;' \
    'esac' > "$FAKEBIN/systemctl"
  chmod +x "$FAKEBIN/systemctl"

  output=$(PATH="$FAKEBIN:$PATH" FM_TEST_SERVICE_PID="$service_pid" \
    $TOOL has --service fake-running.service FM_FAKE_PROCESS_SETTING ABSENT_SETTING 2>&1) \
    || fail "service has failed for a running process"
  expected=$(printf '%s\n' 'FM_FAKE_PROCESS_SETTING=yes' 'ABSENT_SETTING=no')
  [ "$output" = "$expected" ] || fail "service has returned unexpected process booleans: $output"
  assert_no_fake_secret "$output" "service process has"

  kill "$service_pid" 2>/dev/null || true
  wait "$service_pid" 2>/dev/null || true
  trap fm_test_cleanup EXIT
  pass "fm-secrets: service has inspects a running process without exposing values"
}

test_service_has_falls_back_to_unit_settings() {
  local unit_env output expected
  unit_env="$TMP_ROOT/unit.env"
  printf '%s\n' \
    "UNIT_FILE_SETTING=${FAKE_QUOTED}" \
    'UNSET_FILE_SETTING=value' \
    'EXACT_FILE_MATCH=actual' \
    'EXACT_FILE_KEEP=actual' > "$unit_env"
  # shellcheck disable=SC2016 # The generated stub expands these at execution time.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *--property=MainPID*) printf "0\n" ;;' \
    '  *--property=EnvironmentFiles*) printf "%s (ignore_errors=no)\n" "${FM_TEST_UNIT_ENV:?}" ;;' \
    '  *--property=Environment*) printf "INLINE_SETTING=%s UNSET_INLINE_SETTING=value EXACT_INLINE_MATCH=actual EXACT_INLINE_KEEP=actual\n" "${FM_TEST_INLINE_VALUE:?}" ;;' \
    '  *--property=UnsetEnvironment*) printf "UNSET_FILE_SETTING UNSET_INLINE_SETTING EXACT_FILE_MATCH=actual EXACT_FILE_KEEP=other EXACT_INLINE_MATCH=actual EXACT_INLINE_KEEP=other\n" ;;' \
    '  *) exit 64 ;;' \
    'esac' > "$FAKEBIN/systemctl"
  chmod +x "$FAKEBIN/systemctl"

  output=$(PATH="$FAKEBIN:$PATH" FM_TEST_UNIT_ENV="$unit_env" FM_TEST_INLINE_VALUE="$FAKE_INLINE" \
    $TOOL has --service fake-stopped.service UNIT_FILE_SETTING INLINE_SETTING UNSET_FILE_SETTING UNSET_INLINE_SETTING EXACT_FILE_MATCH EXACT_FILE_KEEP EXACT_INLINE_MATCH EXACT_INLINE_KEEP ABSENT_SETTING 2>&1) \
    || fail "service has failed for unit declarations"
  expected=$(printf '%s\n' 'UNIT_FILE_SETTING=yes' 'INLINE_SETTING=yes' 'UNSET_FILE_SETTING=no' 'UNSET_INLINE_SETTING=no' 'EXACT_FILE_MATCH=no' 'EXACT_FILE_KEEP=yes' 'EXACT_INLINE_MATCH=no' 'EXACT_INLINE_KEEP=yes' 'ABSENT_SETTING=no')
  [ "$output" = "$expected" ] || fail "service has returned unexpected unit booleans: $output"
  assert_no_fake_secret "$output" "service declaration has"
  pass "fm-secrets: service has safely reads EnvironmentFile and Environment declarations"
}

test_help_owns_the_scrub_limit() {
  local help
  help=$($TOOL --help) || fail "--help failed"
  assert_contains "$help" 'at least 6 bytes long' "help omitted the scrub threshold"
  assert_contains "$help" 'shorter than 6 bytes' "help omitted the short-value limit"
  assert_contains "$help" 'URL userinfo passwords' "help omitted the URL password exception"
  assert_contains "$help" 'exit status is preserved' "help omitted child status behavior"
  pass "fm-secrets: help documents the scrub boundary"
}

test_names_and_has_never_print_values
test_run_scrubs_all_file_values_and_preserves_status
test_run_excludes_and_scrubs_ambient_secret_settings
test_run_ignores_empty_secret_values
test_run_scrubs_empty_username_url_passwords
test_run_scrubs_url_decoded_passwords
test_service_has_reads_process_environment_without_values
test_service_has_falls_back_to_unit_settings
test_help_owns_the_scrub_limit
