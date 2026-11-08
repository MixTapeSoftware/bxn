#!/bin/bash
# tests/update_all_test.sh
# bxn -ua (update-all): every run leaves a record for the login notice,
# also one that stops partway; a container is left running or stopped as it
# was; a build in progress, or one abandoned, is never started or updated.
# Runs bxn against the fake `incus`.
# Run: bash tests/update_all_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

PASS=0
FAIL=0
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fi
}
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected to contain: $2"; echo "    actual: $3"; fi
}
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected NOT to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
# The readiness wait sleeps between tries; not here.
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/sleep"
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
RECORD="$HOME/.local/state/boxen/last-update"
BOOT="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null | tr -cd '0-9' || echo unknown)"

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_CALL FAKE_INCUS_FAIL_EXEC
  rm -rf "$HOME/.local/state"
}
# box <name> <RUNNING|STOPPED> [build] [builder]
box() {
  incus init images:ubuntu/24.04 "$1" -c user.managed-by=boxen -c user.boxen=1 >/dev/null
  [[ "$2" == STOPPED ]] || incus start "$1"
  [[ -z "${3:-}" ]] || incus config set "$1" "user.boxen.build=$3" "user.boxen.builder=${4:-}"
}
ua() { OUT="$(bash "$REPO_ROOT/bxn" -ua 2>&1)" && RC=0 || RC=$?; }
record() { grep -E '^(status|details)=' "$RECORD" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
status() { cat "$FAKE_INCUS_STATE/instances/$1/status" 2>/dev/null || echo absent; }
started() { grep -qx "start $1" "$FAKE_INCUS_STATE/calls.log" && echo yes || echo no; }
stale() {
  mkdir -p "$(dirname "$RECORD")"
  printf 'status=failed\ndate=2026-11-01 19:00\ndetails=old\n' > "$RECORD"
}

echo "bxn -ua"

fresh
box c1 RUNNING; box c2 STOPPED
ua
assert_eq "a good run: succeeds" "0" "$RC"
assert_eq "a good run: recorded ok" "status=ok details=" "$(record)"
assert_eq "a good run: the stopped one is stopped again" "STOPPED" "$(status c2)"

fresh
box c1 STOPPED; box c2 STOPPED
export FAKE_INCUS_FAIL_CALL='^start c1$'
ua
assert_eq "one won't start: recorded failed, with its name" "status=failed details=c1" "$(record)"
assert_contains "one won't start: says so" "Could not start c1" "$OUT"
assert_contains "one won't start: the next is still updated" "Updated c2" "$OUT"
assert_eq "one won't start: …and stopped again" "STOPPED" "$(status c2)"

fresh
box c1 STOPPED; box c2 STOPPED
export FAKE_INCUS_FAIL_CALL='^stop c1$'
ua
assert_eq "one won't stop: recorded failed, with its name" "status=failed details=c1" "$(record)"
assert_contains "one won't stop: the next is still updated" "Updated c2" "$OUT"

fresh
box c1 RUNNING
export FAKE_INCUS_FAIL_EXEC='apt-get'
ua
assert_eq "an update fails: recorded failed" "status=failed details=c1" "$(record)"

# Under cron, incus is often not on PATH; the list fails before any container.
fresh
box c1 RUNNING
stale
export FAKE_INCUS_FAIL_CALL='^list'
ua
assert_eq "the list fails: exits non-zero" "1" "$RC"
assert_contains "the list fails: recorded failed, not left as it was" "status=failed details=the run stopped before it finished" "$(record)"
assert_not_contains "the list fails: the old record is gone" "details=old" "$(record)"

fresh
stale
ua
assert_eq "nothing to update: succeeds" "0" "$RC"
assert_eq "nothing to update: an old failure is cleared" "status=ok details=" "$(record)"

fresh
box c1 STOPPED
export FAKE_INCUS_FAIL_EXEC='^true$'
ua
assert_contains "it never comes up: says so" "Timed out waiting for c1" "$OUT"
assert_eq "it never comes up: recorded failed" "status=failed details=c1" "$(record)"
assert_eq "it never comes up: stopped again, as it was" "STOPPED" "$(status c1)"

# The log directory can't be made (a file in its place): still recorded.
fresh
box c1 RUNNING
stale
touch "$SANDBOX/notadir"
OUT="$(BOXEN_LOG_DIR="$SANDBOX/notadir/logs" bash "$REPO_ROOT/bxn" -ua 2>&1)" && RC=0 || RC=$?
assert_eq "no log directory: exits non-zero" "1" "$RC"
assert_contains "no log directory: recorded failed" "status=failed details=the run stopped" "$(record)"

echo "builds"

# Still being built: this shell stands in for its bxn create.
fresh
box mid STOPPED running "$$@$BOOT"
box mid2 RUNNING running "$$@$BOOT"
ua
assert_eq "a build in progress: not started" "no" "$(started mid)"
assert_not_contains "a build in progress: not updated" "Updating mid" "$OUT"
assert_contains "a build in progress: says why" "Skipping mid: it's still being built" "$OUT"
assert_eq "a build in progress: not a failure" "status=ok details=" "$(record)"
assert_contains "a running one mid-build: skipped too" "Skipping mid2: it's still being built" "$OUT"
assert_not_contains "…not updated" "Updating mid2" "$OUT"
assert_eq "…and left running" "RUNNING" "$(status mid2)"

# Its bxn create is gone (killed, or failed and kept).
fresh
box half STOPPED running "999999999@$BOOT"
box ok STOPPED done
ua
assert_eq "an abandoned build: not started" "no" "$(started half)"
assert_contains "an abandoned build: says why" "Skipping half: its build didn't finish" "$OUT"
assert_eq "an abandoned build: recorded, so the login notice shows it" "status=failed details=half" "$(record)"
assert_contains "a finished build next to it: updated" "Updated ok" "$OUT"

# Built before the build was recorded: no record at all.
fresh
box old STOPPED
ua
assert_contains "no build record: updated as before" "Updated old" "$OUT"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
