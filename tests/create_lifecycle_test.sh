#!/bin/bash
# tests/create_lifecycle_test.sh
# What bxn create leaves behind, and what it says it left, on the ways a
# build can go. Runs boxen.create end to end against the fake `incus`, with
# curl and git stubbed so nothing is downloaded.
# Run: bash tests/create_lifecycle_test.sh

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
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws" "$SANDBOX/home"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$REPO_ROOT"/bxn "$REPO_ROOT"/bxn.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
echo hello > "$SANDBOX/ws/README"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export XDG_DATA_HOME="$SANDBOX/home/.local/share"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_VERSION=7.5.1
export BOXEN_HANDLE=tester
unset BOXEN_PLUGINS_SOURCE BOXEN_INSECURE_NETWORK

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_CALL FAKE_INCUS_FAIL_EXEC
}
create() { bash "$SANDBOX/repo/boxen.create" "$@" -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$SANDBOX/out")"; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null || true; }
exists() { [[ -d "$FAKE_INCUS_STATE/instances/$1" ]] && echo yes || echo no; }
status() { cat "$FAKE_INCUS_STATE/instances/$1/status" 2>/dev/null || echo absent; }
calls() { cat "$FAKE_INCUS_STATE/calls.log" 2>/dev/null || true; }

# ===========================================================================
echo "a template that carries a workspace"
# ===========================================================================
# Saved before templates were emptied: the builder's files are in it.
fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/old/root/workspace"
echo "the builder's repo" > "$FAKE_INCUS_STATE/images/incus-init/old/root/workspace/OLD"
create --name w --from old --no-tui --egress off
assert_eq "it builds" "0" "$RC"
assert_contains "it says the host directory wasn't copied" "$SANDBOX/ws was NOT copied in" "$OUT"
assert_not_contains "the summary doesn't claim a copy" "Workspace:   copy of" "$OUT"
assert_contains "the summary says whose workspace it is" "Workspace:   the template's own /workspace" "$OUT"

fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/new/root"
create --name w2 --from new --no-tui --egress off
assert_eq "an empty template: it builds" "0" "$RC"
assert_contains "an empty template: the host directory is copied" "Workspace:   copy of $SANDBOX/ws" "$OUT"
assert_not_contains "an empty template: no warning" "NOT copied" "$OUT"

# ===========================================================================
echo "a template whose image already exists"
# ===========================================================================
# Its container was deleted, the image kept.
fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
create -t base --no-tui --egress off
assert_eq "it's refused" "1" "$RC"
assert_contains "it says why, and how to remove it" "incus image delete incus-init/base" "$OUT"
assert_eq "before anything is made" "no" "$(exists base)"
assert_eq "…or started" "" "$(grep -E '^(init|launch|publish) ' <<< "$(calls)" || true)"

fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
create -t base --no-tui --egress off --dry-run
assert_eq "a dry run is refused the same way" "1" "$RC"

fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/other/root"
create -t base --no-tui --egress off --dry-run
assert_eq "another template's image: no clash" "0" "$RC"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
