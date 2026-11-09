#!/bin/bash
# tests/egress_register_test.sh
# `bxn egress` and the egress containers' registration: allow and rm on a
# container without an allowlist, a proxy add that failed, an old proxy left
# under a reused name, a rebuilt egress container, a container that only has
# an egress container's name, and an address that can't be had. Each must
# end with the agent's card, its proxy and its recorded port agreeing, or
# fail without changing anything. Runs against the fake `incus` and ctl.
# Run: bash tests/egress_register_test.sh

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
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; echo "    actual: $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
cp "$REPO_ROOT"/bxn "$REPO_ROOT"/bxn.* "$REPO_ROOT"/boxen.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_STATE="$SANDBOX/state"
export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
export FAKE_INCUS_VERSION=7.5.1
mkdir -p "$FAKE_INCUS_STATE"

eg() { bash "$SANDBOX/repo/bxn" egress "$@"; }
run() { OUT="$(eg "$@" 2>&1)" && RC=0 || RC=$?; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
status() { cat "$FAKE_INCUS_STATE/instances/$1/status"; }
E=boxen-egress
gen_of() { cat "$FAKE_INCUS_STATE/ctl/$E/$1/current"; }
gen_file() { cat "$FAKE_INCUS_STATE/ctl/$E/$1/gens/$(gen_of "$1")/$2"; }
calls_since() { tail -n +"$(( $1 + 1 ))" "$FAKE_INCUS_STATE/calls.log"; }
ncalls() { wc -l < "$FAKE_INCUS_STATE/calls.log" | tr -d ' '; }
# yes when <container>'s current proxy generation allows <host>
allows() { grep -qxF -- "$2" <<< "$(gen_file "$1" hosts)" && echo yes || echo no; }

make_box() {
  incus launch img "$1" -p default -p boxen-net -d "eth0,ipv4.address=$2" >/dev/null
  incus config set "$1" user.managed-by=boxen user.boxen.net=isolated
}
bash -c 'log(){ :; }; warn(){ :; }; error(){ exit 1; }; source "$1/boxen.net"; ensure_net' _ "$SANDBOX/repo"
ctl_port() { cat "$FAKE_INCUS_STATE/ctl/$E/$1/port" 2>/dev/null; }
nadds() { grep -c "^add $1 " "$FAKE_INCUS_STATE/ctl/$E/calls.log" || true; }

echo "allow and rm on a container without an allowlist"
make_box off1 10.201.0.40
incus stop off1
run allow off1 docs.rs
assert_eq "allow fails" "1" "$RC"
assert_contains "it says how to turn the allowlist on" "off1 has no allowlist. Turn it on first: bxn egress mode off1 enforce" "$OUT"
assert_eq "it isn't registered" "" "$(cfg off1 user.boxen.egress.container)"
assert_eq "it isn't started" "STOPPED" "$(status off1)"
assert_eq "no proxy settings are written" "" "$(cfg off1 environment.HTTPS_PROXY)"
run rm off1 docs.rs
assert_eq "rm fails" "1" "$RC"
assert_contains "the same way" "off1 has no allowlist" "$OUT"
run baseline off1 off
assert_eq "baseline fails" "1" "$RC"
assert_contains "…the same way" "off1 has no allowlist. Turn it on first: bxn egress mode off1 enforce" "$OUT"
assert_eq "…leaving it unregistered" "" "$(cfg off1 user.boxen.egress.container)"
assert_eq "…and stopped" "STOPPED" "$(status off1)"
assert_eq "…with nothing recorded" "" "$(cfg off1 user.boxen.egress.baseline)"
run allow off1 'not a host'
assert_eq "a bad host fails" "1" "$RC"
assert_contains "a bad host is refused first" "Not a hostname bxn accepts: not a host" "$OUT"
assert_eq "still unregistered" "" "$(cfg off1 user.boxen.egress.container)"
run allow off1
assert_eq "no host is a usage error" "1" "$RC"
assert_eq "and changes nothing" "STOPPED" "$(status off1)"
run ls
assert_not_contains "ls doesn't list it" "off1" "$OUT"

echo "a registered container without a mode locks as enforce"
make_box nomode 10.201.0.41
run mode nomode off
incus config unset nomode user.boxen.egress
run refresh nomode
assert_eq "refresh succeeds" "0" "$RC"
assert_eq "its card is locked" "reject" "$(cfg nomode devices.eth0.security.acls.default.egress.action)"
assert_eq "its proxy enforces" "enforce" "$(gen_file nomode mode)"

echo "a proxy add that failed"
make_box box 10.201.0.50
FAKE_EGRESS_CTL_FAIL='^add box ' run mode box enforce
assert_eq "the first try fails" "1" "$RC"
assert_eq "box is registered (nomode has 10000)" "10001" "$(cfg box user.boxen.egress.port)"
run mode box enforce
assert_eq "a retry succeeds" "0" "$RC"
assert_eq "it added the proxy again" "2" "$(nadds box)"
assert_eq "box runs" "RUNNING" "$(status box)"
assert_eq "the barrier is cleared" "none" "$(cfg box user.boxen.egress.transition)"
assert_eq "the proxy is on box's port" "10001" "$(ctl_port box)"

echo "an old proxy under a reused name"
incus stop "$E"
bash "$SANDBOX/repo/bxn" rm box >/dev/null 2>&1
incus start "$E"
assert_eq "the old proxy stayed" "10001" "$(ctl_port box)"
make_box box 10.201.0.51
run mode box enforce
assert_eq "the new box locks" "0" "$RC"
assert_eq "on a new port" "10002" "$(cfg box user.boxen.egress.port)"
assert_eq "its proxy listens there" "10002" "$(ctl_port box)"
assert_eq "its proxy settings name it" "http://10.201.0.10:10002" "$(cfg box environment.HTTPS_PROXY)"
echo 10077 > "$FAKE_INCUS_STATE/ctl/$E/box/port"
run ls
assert_contains "ls notices a proxy on another port" "its proxy listens on 10077, not 10002" "$OUT"
run refresh box
assert_eq "refresh fixes it" "0" "$RC"
assert_contains "and says so" "replacing it" "$OUT"
assert_eq "the proxy is on box's port again" "10002" "$(ctl_port box)"
run ls
assert_eq "ls succeeds" "0" "$RC"
assert_contains "and lists box" "box  " "$(grep '^box ' <<< "$OUT")"
assert_not_contains "with its proxy listening" "no proxy" "$(grep '^box ' <<< "$OUT")"

echo "a proxy whose policy isn't the recorded one"
echo deadbeefdeadbeef > "$FAKE_INCUS_STATE/ctl/$E/box/gens/$(gen_of box)/policy"
run ls
assert_contains "ls notices" "its proxy runs another policy than recorded: bxn egress refresh box" "$OUT"
run refresh box
run ls
assert_not_contains "refresh puts it right" "another policy" "$OUT"

echo "a rebuilt egress container"
make_box a 10.201.0.60
run mode a enforce
a_port="$(cfg a user.boxen.egress.port)"
old_eip="$(cfg "$E" devices.eth0.ipv4.address)"
incus delete --force "$E"; rm -rf "$FAKE_INCUS_STATE/ctl/$E"
make_box b 10.201.0.70
run mode b enforce
assert_eq "b locks" "0" "$RC"
new_eip="$(cfg "$E" devices.eth0.ipv4.address)"
assert_eq "the egress container has a new address" "yes" "$([[ "$new_eip" != "$old_eip" ]] && echo yes || echo no)"
assert_eq "b gets a port above a's" "yes" "$( (( $(cfg b user.boxen.egress.port) > a_port )) && echo yes || echo no)"
run refresh a
assert_eq "refresh brings a back" "0" "$RC"
assert_eq "a's proxy is on a's port" "$a_port" "$(ctl_port a)"
assert_contains "a's rules point at the new egress container" "destination: $new_eip/32" "$(cat "$FAKE_INCUS_STATE/acls/boxen-a-a")"
assert_eq "a's proxy settings too" "http://$new_eip:$a_port" "$(cfg a environment.HTTPS_PROXY)"
assert_contains "the egress container admits a on its port" "destination_port: \"$a_port\"
  description: a" "$(cat "$FAKE_INCUS_STATE/acls/$E")"
run mode a off
assert_eq "and a can be turned off" "0" "$RC"
incus delete --force "$E"; rm -rf "$FAKE_INCUS_STATE/ctl/$E"
run refresh a
assert_eq "refresh recreates a missing egress container" "0" "$RC"
assert_eq "with a's proxy" "$a_port" "$(ctl_port a)"

echo "a container that only has an egress container's name"
make_box boxen-egress-x 10.201.0.80
make_box c 10.201.0.81
run mode c enforce --egress-container x
assert_eq "it isn't used" "1" "$RC"
assert_contains "it says why" "boxen-egress-x exists but isn't an egress container bxn made" "$OUT"
assert_eq "it isn't set up" "" "$(cfg boxen-egress-x user.boxen.egress.ready)"
assert_eq "no proxy runs in it" "no" "$([[ -d "$FAKE_INCUS_STATE/ctl/boxen-egress-x" ]] && echo yes || echo no)"

echo "an address that can't be had"
make_box d 10.201.0.90
run mode d off
FAKE_INCUS_FAIL_CALL='^network set boxenbr0 user.boxen.next-address' run mode d enforce
assert_eq "turning it on fails" "1" "$RC"
assert_contains "it says why" "Could not find a new address for d" "$OUT"
assert_eq "its card is untouched" "allow" "$(cfg d devices.eth0.security.acls.default.egress.action)"
assert_eq "its address too" "10.201.0.90" "$(cfg d devices.eth0.ipv4.address)"
assert_eq "no barrier is set" "" "$(cfg d user.boxen.egress.transition | sed 's/^none$//')"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
