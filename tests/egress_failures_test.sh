#!/bin/bash
# tests/egress_failures_test.sh
# `bxn egress` when something fails or races: a bad line in a host list, a
# mode change that doesn't go through, a container locked while --all waits
# for its answer, and a status that can't be read during a lockdown. Each
# must fail closed: the command exits non-zero, nothing gets looser, and ls
# shows what's wrong. Runs against the fake `incus` and the fake ctl.
# Run: bash tests/egress_failures_test.sh

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

echo "a bad line in a host list"
make_box box 10.201.0.50
run mode box enforce
run allow box docs.rs
assert_eq "docs.rs is allowed" yes "$(allows box docs.rs)"
good_gen="$(gen_of box)"
good_active="$(cfg box user.boxen.egress.active)"
printf 'good.example.com\nbad_host!\n' > "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run allow box crates.io
assert_eq "a change fails" "1" "$RC"
assert_contains "it names the bad line" "egress-baseline.txt line 2: not a hostname bxn accepts: bad_host!" "$OUT"
assert_eq "the proxy keeps its policy" "$good_gen" "$(gen_of box)"
assert_eq "so the container's own hosts stay allowed" yes "$(allows box docs.rs)"
assert_eq "the applied policy stays recorded" "$good_active" "$(cfg box user.boxen.egress.active)"
run refresh box
assert_eq "refresh fails too" "1" "$RC"
assert_eq "and changes nothing" "$good_gen" "$(gen_of box)"
run ls
assert_contains "ls says the lists can't be read" "can't read its host lists" "$OUT"
run ls box
assert_eq "ls of the container fails" "1" "$RC"
assert_contains "and says why" "bad_host!" "$OUT"
run rm box docs.rs
assert_eq "rm fails" "1" "$RC"
assert_eq "the proxy still allows docs.rs" yes "$(allows box docs.rs)"
cp "$BOXEN_CONFIG_DIR/egress-approved-baseline.txt" "$SANDBOX/approved.txt"
printf 'bad_host!\n' > "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run allow --all crates.io --yes
assert_eq "allow --all refuses a bad additions file" "1" "$RC"
assert_eq "and leaves it as it was" "bad_host!" "$(cat "$BOXEN_CONFIG_DIR/egress-baseline.txt")"
rm -f "$BOXEN_CONFIG_DIR/egress-baseline.txt"
printf 'ok.example\nbad_host!\n' > "$BOXEN_CONFIG_DIR/egress-approved-baseline.txt"
run allow box crates.io
assert_eq "a bad approved baseline fails a change" "1" "$RC"
assert_eq "and the proxy keeps the baseline's hosts" yes "$(allows box api.anthropic.com)"
cp "$SANDBOX/approved.txt" "$BOXEN_CONFIG_DIR/egress-approved-baseline.txt"
run refresh box
assert_eq "once fixed, refresh applies the change" "0" "$RC"
assert_eq "crates.io is allowed" yes "$(allows box crates.io)"
assert_eq "docs.rs is still allowed" yes "$(allows box docs.rs)"
run ls
assert_not_contains "ls has nothing to say" "can't read" "$OUT"

echo "a host list that can't be read"
printf 'extra.example\n' > "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run refresh box
assert_eq "box allows your addition" yes "$(allows box extra.example)"
good_gen="$(gen_of box)"
chmod 000 "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run allow --all more.example --yes
assert_eq "allow --all fails" "1" "$RC"
assert_contains "it names the file" "Could not read $BOXEN_CONFIG_DIR/egress-baseline.txt" "$OUT"
chmod 600 "$BOXEN_CONFIG_DIR/egress-baseline.txt"
assert_eq "your additions are kept" "extra.example" "$(cat "$BOXEN_CONFIG_DIR/egress-baseline.txt")"
chmod 000 "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run refresh box
assert_eq "refresh fails" "1" "$RC"
chmod 600 "$BOXEN_CONFIG_DIR/egress-baseline.txt"
assert_eq "and box's proxy keeps them" "$good_gen" "$(gen_of box)"
rm -f "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run refresh box

echo "a container list that can't be read under the lock"
# The first list, for the question, works; the second, under the lock, fails.
mv "$SANDBOX/bin/incus" "$SANDBOX/bin/incus.real"
cat > "$SANDBOX/bin/incus" <<'W'
#!/usr/bin/env bash
if [[ "$*" == "list user.managed-by=boxen --format csv --columns n" ]]; then
  n="$(cat "$FAKE_INCUS_STATE/nlist" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$FAKE_INCUS_STATE/nlist"
  [[ "$n" -ge 1 ]] && exit 1
fi
exec "$(dirname "$0")/incus.real" "$@"
W
chmod +x "$SANDBOX/bin/incus"
run allow --all listfail.example --yes
mv "$SANDBOX/bin/incus.real" "$SANDBOX/bin/incus"
assert_eq "allow --all fails" "1" "$RC"
assert_contains "and says to refresh" "no container got them. Retry: bxn egress refresh --all" "$OUT"
run refresh --all
assert_eq "the retry applies it" yes "$(allows box listfail.example)"
rm -f "$BOXEN_CONFIG_DIR/egress-baseline.txt"
run refresh --all

echo "a looser mode that doesn't go through isn't kept"
make_box c 10.201.0.60
run mode c enforce
FAKE_EGRESS_CTL_FAIL='^gen c ' run mode c off
assert_eq "mode off fails when its policy can't be written" "1" "$RC"
assert_contains "it says the mode stays" "c stays enforce" "$OUT"
assert_eq "the recorded mode stays enforce" "enforce" "$(cfg c user.boxen.egress)"
assert_eq "the card stays locked" "reject" "$(cfg c devices.eth0.security.acls.default.egress.action)"
run allow c crates.io
assert_eq "a later allow succeeds" "0" "$RC"
assert_eq "it doesn't turn the allowlist off" "reject" "$(cfg c devices.eth0.security.acls.default.egress.action)"
assert_eq "the proxy enforces" "enforce" "$(gen_file c mode)"
assert_eq "the mode is still enforce" "enforce" "$(cfg c user.boxen.egress)"
run mode c report
assert_eq "report goes through" "0" "$RC"
FAKE_EGRESS_CTL_FAIL='^gen c ' run mode c enforce
assert_eq "a stricter mode that fails fails too" "1" "$RC"
assert_eq "but it's kept, so a retry finishes it" "enforce" "$(cfg c user.boxen.egress)"
run allow c docs.rs
assert_eq "a later allow applies it" "enforce" "$(gen_file c mode)"
assert_contains "and says the mode changed" "c: now enforce (was report)" "$OUT"

echo "allow --all lists its containers under the lock"
make_box box2 10.201.0.70
run allow --all bulk.example --yes
assert_eq "box allows bulk.example" yes "$(allows box bulk.example)"
# Once rm --all has listed the allowlisted containers for its prompt, another
# bxn turns box2's allowlist on, with bulk.example still in the additions.
mv "$SANDBOX/bin/incus" "$SANDBOX/bin/incus.real"
cat > "$SANDBOX/bin/incus" <<'W'
#!/usr/bin/env bash
out="$("$(dirname "$0")/incus.real" "$@")"; rc=$?
if [[ "$*" == "config get boxen-egress user.boxen.egress.container" && -f "$FAKE_INCUS_STATE/hook" ]]; then
  rm -f "$FAKE_INCUS_STATE/hook"
  bash "$HOOK_BXN" egress mode box2 enforce </dev/null >"$FAKE_INCUS_STATE/hook.out" 2>&1
fi
[[ -n "$out" ]] && printf '%s\n' "$out"; exit $rc
W
chmod +x "$SANDBOX/bin/incus"
export HOOK_BXN="$SANDBOX/repo/bxn"
touch "$FAKE_INCUS_STATE/hook"
run rm --all bulk.example --yes
mv "$SANDBOX/bin/incus.real" "$SANDBOX/bin/incus"
assert_eq "it succeeds" "0" "$RC"
assert_contains "box2 was locked meanwhile" "locked" "$(cat "$FAKE_INCUS_STATE/hook.out")"
assert_eq "box's proxy drops bulk.example" no "$(allows box bulk.example)"
assert_eq "and so does box2's" no "$(allows box2 bulk.example)"
run ls
assert_not_contains "ls has nothing to refresh" "hosts changed since applied" "$OUT"

echo "a lockdown whose container status can't be read"
make_box d 10.201.0.80
run mode d enforce
run mode d off
before="$(ncalls)"
FAKE_INCUS_FAIL_CALL='^list \^d\$' run mode d enforce
assert_eq "it fails" "1" "$RC"
assert_contains "it says it couldn't read the status" "Could not read d's status" "$OUT"
assert_eq "the card isn't touched while d may run" "allow" "$(cfg d devices.eth0.security.acls.default.egress.action)"
assert_not_contains "nor its address" "config device set d eth0 ipv4.address" "$(calls_since "$before")"
assert_eq "d won't start on its own" "false" "$(cfg d boot.autostart)"
run refresh d
assert_eq "a retry finishes it" "0" "$RC"
assert_eq "d is locked" "reject" "$(cfg d devices.eth0.security.acls.default.egress.action)"
assert_eq "and runs" "RUNNING" "$(status d)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
