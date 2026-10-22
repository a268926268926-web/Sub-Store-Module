#!/system/bin/sh
# Isolated shell tests for the persistent automatic updater.
# Run with any POSIX sh; no root or real component downloads are used.

set -u

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(CDPATH= cd "$TEST_DIR/../scripts" && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/substore-auto-update.XXXXXX")
export SUB_STORE_TEST_ROOT="$TEST_ROOT"
export TZ=UTC
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/run"
cp "$SCRIPTS_DIR/sub_store.config" "$SCRIPTS_DIR/sub_store.env" "$TEST_ROOT/scripts/"

cleanup() {
  sh "$SCRIPTS_DIR/auto_update_daemon.sh" stop >/dev/null 2>&1 || true
  if [ "${KEEP_TEST_ROOT:-0}" = "1" ]; then
    echo "TEST_ROOT kept: $TEST_ROOT"
  else
    rm -rf "$TEST_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected: $2, actual: $1)"
}

json_check() {
  node -e "$2" "$1" >/dev/null 2>&1 || fail "$3"
}

. "$SCRIPTS_DIR/lib.sh"
load_config
. "$SCRIPTS_DIR/auto_update_lib.sh"
auto_update_init_paths

# 1. Missing config is valid, present, and disabled by default.
status=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-status) || fail "auto-update-status failed"
[ "$(printf '%s\n' "$status" | wc -l)" -eq 1 ] || fail "status JSON must be one line"
json_check "$status" '
  const x = JSON.parse(process.argv[1]);
  if (x.success !== true || x.enabled !== false || x.schedule !== "daily") process.exit(1);
  if (x.hour !== 3 || x.minute !== 0 || x.nextRun !== null) process.exit(1);
' "default status contract"
echo "PASS default disabled status"
disabled_daemon=$(sh "$SCRIPTS_DIR/auto_update_daemon.sh" start) || fail "disabled daemon start should be a no-op"
assert_eq "$disabled_daemon" "disabled" "disabled daemon start output"
auto_update_daemon_running && fail "disabled configuration started the daemon"
echo "PASS disabled configuration keeps daemon stopped"

# 2. Invalid config is rejected atomically; valid config is persisted.
invalid=$(printf '%s' '{"enabled":true,"schedule":"daily","hour":25,"minute":0}' | base64 | tr -d '\n')
invalid_output=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-config "$invalid" 2>/dev/null)
invalid_rc=$?
if [ "$invalid_rc" -eq 0 ]; then
  fail "invalid config was accepted"
fi
json_check "$invalid_output" '
  const x = JSON.parse(process.argv[1]);
  if (x.success !== false || x.enabled !== false || !x.error) process.exit(1);
' "invalid config must return a JSON status"
[ ! -f "$AUTO_CONFIG_FILE" ] || fail "invalid config created the config file"

valid=$(printf '%s' '{"enabled":true,"schedule":"weekly","weekday":2,"hour":4,"minute":15,"intervalDays":9}' | base64 | tr -d '\n')
configured=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-config "$valid") || fail "valid config was rejected"
json_check "$configured" '
  const x = JSON.parse(process.argv[1]);
  if (x.success !== true || x.enabled !== true || x.schedule !== "weekly") process.exit(1);
  if (x.weekday !== 2 || x.hour !== 4 || x.minute !== 15) process.exit(1);
' "saved config status contract"
grep -q '^enabled=true$' "$AUTO_CONFIG_FILE" || fail "enabled was not persisted"
grep -q '^schedule=weekly$' "$AUTO_CONFIG_FILE" || fail "schedule was not persisted"

# The WebUI now emits interval_days for every user-selected period, including
# one day. Verify the full supported range survives the shell/JSON boundary.
for interval in 1 3 7 30 365; do
  interval_payload=$(printf '%s' "{\"enabled\":true,\"schedule\":\"interval_days\",\"hour\":4,\"minute\":30,\"intervalDays\":$interval}" | base64 | tr -d '\n')
  interval_output=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-config "$interval_payload") \
    || fail "intervalDays=$interval was rejected"
  json_check "$interval_output" "
    const x = JSON.parse(process.argv[1]);
    if (x.success !== true || x.schedule !== \"interval_days\") process.exit(1);
    if (x.intervalDays !== $interval) process.exit(1);
  " "intervalDays=$interval status contract"
  grep -q '^schedule=interval_days$' "$AUTO_CONFIG_FILE" \
    || fail "interval schedule was not persisted for $interval days"
  grep -q "^interval_days=$interval$" "$AUTO_CONFIG_FILE" \
    || fail "intervalDays=$interval was not persisted"
done
auto_update_daemon_stop
echo "PASS config validation and atomic persistence"

# 3. The detached daemon ignores HUP so closing the WebUI cannot stop it.
auto_update_daemon_start || fail "daemon did not start"
read -r daemon_pid _ <"$AUTO_DAEMON_LOCK_DIR/owner" || fail "daemon PID was not recorded"
kill -HUP "$daemon_pid"
sleep 0.3
auto_update_daemon_running || fail "daemon exited after HUP"
auto_update_daemon_stop
echo "PASS daemon survives HUP"

# 4. Disabling the schedule stops the persistent daemon again.
disabled=$(printf '%s' '{"enabled":false}' | base64 | tr -d '\n')
disabled_output=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-config "$disabled") || fail "disable config failed"
json_check "$disabled_output" '
  const x = JSON.parse(process.argv[1]);
  if (x.success !== true || x.enabled !== false || x.daemonRunning !== false) process.exit(1);
' "disabled config should stop daemon"
auto_update_daemon_running && fail "daemon remained running after disable"
echo "PASS disable stops daemon"

# 5. nextRun calculations are deterministic and use local wall-clock fields.
AUTO_CFG_ENABLED=true
AUTO_CFG_VALID=true
AUTO_CFG_SCHEDULE=daily
AUTO_CFG_INTERVAL_DAYS=7
AUTO_CFG_WEEKDAY=1
AUTO_CFG_HOUR=3
AUTO_CFG_MINUTE=0
base=1704067200 # 2024-01-01 00:00:00 UTC, Monday
assert_eq "$(auto_update_next_epoch "$base")" "$((base + 10800))" "daily nextRun"

AUTO_CFG_SCHEDULE=weekly
AUTO_CFG_WEEKDAY=1
assert_eq "$(auto_update_next_epoch "$((base + 3600))")" "$((base + 10800))" "weekly Monday nextRun"
AUTO_CFG_WEEKDAY=2
assert_eq "$(auto_update_next_epoch "$base")" "$((base + 86400 + 10800))" "weekly Tuesday nextRun"

AUTO_CFG_SCHEDULE=interval_days
AUTO_CFG_INTERVAL_DAYS=2
assert_eq "$(auto_update_next_epoch "$base")" "$((base + 2 * 86400 + 10800))" "interval nextRun"

AUTO_CFG_SCHEDULE=daily
assert_eq "$(auto_update_next_epoch "$((base + 4 * 3600))")" "$((base + 86400 + 10800))" "daily passed-time rollover"
echo "PASS nextRun calculation"

# 6. A live lock rejects a competing updater; release allows the next owner.
update_lock_acquire || fail "could not acquire test update lock"
(
  . "$SCRIPTS_DIR/lib.sh"
  load_config
  . "$SCRIPTS_DIR/auto_update_lib.sh"
  auto_update_init_paths
  update_lock_acquire
) >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "live lock did not reject a competing updater"
update_lock_release
update_lock_acquire || fail "lock was not reusable after release"
update_lock_release
echo "PASS lock mutual exclusion"

# 7. A dead owner is reclaimed as a stale lock.
mkdir -p "$AUTO_UPDATE_LOCK_DIR"
printf '999999 1\n' >"$AUTO_UPDATE_LOCK_DIR/owner"
update_lock_acquire || fail "stale lock was not reclaimed"
update_lock_release
echo "PASS stale lock recovery"

# 8. A failed aggregate update restores the component snapshot. The fake
#    downloader lets the backend succeed and forces the frontend to fail.
mkdir -p "$TEST_ROOT/test-bin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$TEST_ROOT/test-bin/pidof"
chmod 755 "$TEST_ROOT/test-bin/pidof"
printf '%s\n' \
  '#!/bin/sh' \
  'out=""' \
  'all="$*"' \
  'while [ "$#" -gt 0 ]; do' \
  '  [ "$1" = "-o" ] && out=$2' \
  '  shift' \
  'done' \
  'case "$all" in' \
  '  *Sub-Store-Front-End*) exit 1 ;;' \
  '  *sub-store-org/Sub-Store/releases*)' \
  '    printf "/*\\nSUB_STORE_BACKEND_VERSION: 9.0.0\\n*/\\n" >"$out"' \
  '    dd if=/dev/zero bs=120000 count=1 >>"$out" 2>/dev/null' \
  '    ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$TEST_ROOT/test-bin/curl"
chmod 755 "$TEST_ROOT/test-bin/curl"
export PATH="$TEST_ROOT/test-bin:$PATH"

mkdir -p "$TEST_ROOT/bin/frontend"
printf '/*\nSUB_STORE_BACKEND_VERSION: 1.0.0\n*/\n' >"$TEST_ROOT/bin/sub-store.bundle.js"
dd if=/dev/zero bs=120000 count=1 >>"$TEST_ROOT/bin/sub-store.bundle.js" 2>/dev/null
printf '1.0.0\n' >"$TEST_ROOT/bin/backend_version"
if aggregate_output=$(sh "$SCRIPTS_DIR/update_all.sh" sub-store 2>&1); then
  fail "aggregate update unexpectedly succeeded"
fi
grep -q 'SUB_STORE_BACKEND_VERSION: 1.0.0' "$TEST_ROOT/bin/sub-store.bundle.js" \
  || {
    printf '%s\n' "$aggregate_output" >&2
    fail "aggregate rollback did not restore the old backend"
  }
[ "$(cat "$TEST_ROOT/bin/backend_version")" = "1.0.0" ] \
  || {
    printf '%s\n' "$aggregate_output" >&2
    fail "aggregate rollback did not restore the backend version"
  }
echo "PASS aggregate rollback"

# 9. run-now returns accepted JSON and records a bounded, non-network failure
#    when the service is intentionally reported as stopped.
run_output=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-run-now) || fail "run-now was not accepted"
json_check "$run_output" '
  const x = JSON.parse(process.argv[1]);
  if (x.success !== true || x.accepted !== true || x.pid <= 0) process.exit(1);
' "run-now contract"

i=0
while auto_update_job_running && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ "$i" -lt 50 ] || fail "run-now test job did not finish"
sleep 0.2
final_status=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-status) || fail "status after run-now failed"
json_check "$final_status" '
  const x = JSON.parse(process.argv[1]);
  if (x.lastStatus !== "failed" || !x.lastResult) process.exit(1);
' "run-now failure status"
auto_log=$(sh "$SCRIPTS_DIR/webui.sh" auto-update-log) || fail "auto-update-log failed"
[ -n "$auto_log" ] || fail "auto-update-log is empty after run-now"
echo "PASS run-now JSON and failure state"

echo "ALL AUTO UPDATE TESTS PASSED"
