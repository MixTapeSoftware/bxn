#!/bin/bash
# tests/container_warning_test.sh
# PLUGIN_CONTAINER_WARNING: a plugin that is safer in a VM says why when it's
# picked for a container, once with the selection and again in the summary,
# and says nothing in a VM or when it isn't picked. The Docker plugin sets one.
# Run: bash tests/container_warning_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null
command -v jq >/dev/null || { echo "needs jq (the host's memory comes from the resources API)"; exit 1; }

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
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
cat > "$SANDBOX/repo/plugins/10-relaxed.sh" <<'PLUGIN'
PLUGIN_ID="relaxed"; PLUGIN_NAME="Relaxed"; PLUGIN_DESC="needs a looser sandbox"; PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--relaxed"
PLUGIN_CONTAINER_WARNING="safer with --vm"
plugin_install() { :; }
PLUGIN
cat > "$SANDBOX/repo/plugins/20-plain.sh" <<'PLUGIN'
PLUGIN_ID="plain"; PLUGIN_NAME="Plain"; PLUGIN_DESC="fine anywhere"; PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--plain"
plugin_install() { :; }
PLUGIN
echo hello > "$SANDBOX/ws/README"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_INCUS_VERSION=7.5.1

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
}
init() { local n="$1"; shift; bash "$SANDBOX/repo/boxen.create" --name "$n" "$@" --egress off --no-tui -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
out() { sed -e $'s/\033\\[[0-9;]*m//g' "$SANDBOX/out"; }

echo "picked for a container"
fresh
init box --relaxed --plain
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_contains "it warns with the selection" "[!] Relaxed: safer with --vm" "$(out)"
assert_contains "and again in the summary" "Notes:
  Relaxed: safer with --vm" "$(out)"
assert_eq "once each" "2" "$(out | grep -c 'Relaxed: safer with --vm')"
assert_not_contains "a plugin without one says nothing" "Plain:" "$(out)"

echo "not picked"
fresh
init box2 --plain
assert_eq "it builds" "0" "$RC"
assert_not_contains "no warning" "safer with --vm" "$(out)"
assert_not_contains "and no notes" "Notes:" "$(out)"

echo "picked for a VM"
fresh
init vbox --relaxed --vm --dry-run
assert_eq "the dry run works" "0" "$RC"
assert_not_contains "no warning in a VM" "safer with --vm" "$(out)"

echo "a dry run for a container"
fresh
init dbox --relaxed --dry-run
assert_contains "warns too" "[!] Relaxed: safer with --vm" "$(out)"

echo "the Docker plugin"
docker_warning="$(bash -c 'source "$1"; echo "$PLUGIN_CONTAINER_WARNING"' _ "$REPO_ROOT/plugins/10-docker.sh")"
assert_contains "sets one that points at --vm" "With --vm, Docker gets its own kernel" "$docker_warning"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
