#!/bin/bash
# tests/egress_ctl_state_test.sh
# The real egress/boxen-egress-ctl against a fake systemd (tests/lib/fake_systemd):
# how proxy generations move through widen, tighten, check, stop, remove and
# boot when a command is cut short or two of them meet.
# tests/host/egress_ctl_test.sh runs it with the real systemd and smokescreen.
# Needs flock and jq, so Linux.
# Run: bash tests/egress_ctl_state_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

for t in flock jq; do
  command -v "$t" >/dev/null || { echo "skip: needs $t"; exit 0; }
done

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
mkdir -p "$SANDBOX/bin"
for t in systemctl journalctl systemd-escape curl sleep; do
  ln -s "$SCRIPT_DIR/lib/fake_systemd" "$SANDBOX/bin/$t"
done
export PATH="$SANDBOX/bin:$PATH"

# A new egress container: the ctl with its paths moved into a fresh state dir.
fresh() {
  S="$SANDBOX/s$RANDOM$RANDOM"
  mkdir -p "$S/etc" "$S/units" "$S/run" "$S/systemd"
  export FAKE_SYSTEMD="$S/systemd" FAKE_SYSTEMD_ETC="$S/etc"
  sed -e "s|^ETC=.*|ETC=$S/etc|" \
      -e "s|^UNITS=.*|UNITS=$S/units|" \
      -e "s|/run/|$S/run/|g" \
      "$REPO_ROOT/egress/boxen-egress-ctl" > "$S/ctl"
  ctl setup 1.1.1.1 "" >/dev/null
}
ctl() { bash "$S/ctl" "$@"; }
# Runs the ctl, keeping its output and exit code.
run() { OUT="$(ctl "$@" 2>&1)" && RC=0 || RC=$?; }
gen() { local agent="$1" mode="$2" policy="$3"; shift 3; printf '%s\n' "$@" | ctl gen "$agent" "$mode" "$policy"; }
unit_state() { if [[ -f "$FAKE_SYSTEMD/units/$1" ]]; then cut -d' ' -f1 "$FAKE_SYSTEMD/units/$1"; else echo inactive; fi; }
listening() { ctl status "$1" | cut -f6; }
active_gens() { ctl status "$1" | cut -f7; }
# Every unit stops, as at a reboot of the egress container.
reboot() {
  local f
  for f in "$FAKE_SYSTEMD/units"/*; do echo "inactive 0" > "$f"; done
  rm -f "$FAKE_SYSTEMD/port4700"
}
# A serves h1 and a wider list from gen 1; gen 2 narrows it to h1.
serving_wide() {
  fresh
  ctl add a 4750
  gen a enforce 1111aaaa h1.example.com wide.example.com >/dev/null
  ctl widen a 1
  gen a enforce 2222bbbb h1.example.com >/dev/null
}

echo "boot and a host change don't interleave"
serving_wide
reboot
assert_eq "after a reboot nothing listens" "no" "$(listening a)"
( FAKE_SYSTEMD_HOLD_DELAY=1 ctl boot ) &
BOOT=$!
for _ in $(seq 1 100); do [[ -f "$FAKE_SYSTEMD/hold-starting" ]] && break; /bin/sleep 0.05; done
# The host sees listening=no, so it tightens while boot is partway through.
run tighten a 2
wait "$BOOT"
assert_eq "the tighten went through" "0" "$RC"
assert_eq "only the narrower generation runs" "2" "$(active_gens a)"
assert_eq "the wider one isn't left accepting" "inactive" "$(unit_state 'boxen-gen_a@1.service')"
assert_eq "current is the narrower one" "2" "$(ctl status a | cut -f3)"

echo "boot waits for a change that holds the lock"
serving_wide
reboot
( flock 9; touch "$S/held"; /bin/sleep 1 ) 9>"$S/run/boxen-egress-ctl.lock" &
HOLDER=$!
for _ in $(seq 1 100); do [[ -f "$S/held" ]] && break; /bin/sleep 0.05; done
ctl boot &
BOOT=$!
/bin/sleep 0.3
assert_eq "boot hasn't started anything while the lock is held" "inactive" "$(unit_state 'boxen-gen_a@1.service')"
wait "$HOLDER" "$BOOT"
assert_eq "then it starts the current generation" "active" "$(unit_state 'boxen-gen_a@1.service')"

echo "a direct check that gets no record stops its check copy"
fresh
ctl add a 4750; ctl add b 4751
gen a enforce 1111aaaa h1.example.com >/dev/null
FAKE_CURL_LATE=1 run check a 1
assert_eq "the check fails" "1" "$RC"
assert_contains "and says why" "wrong decision for the probe: no record" "$OUT"
assert_eq "its check copy is stopped" "inactive" "$(unit_state 'boxen-check_a@1.service')"
gen b enforce 3333cccc h2.example.com >/dev/null
run widen b 1
assert_eq "a later check for another agent passes" "0" "$RC"

echo "a check copy left by a killed ctl doesn't block later checks"
fresh
ctl add a 4750; ctl add b 4751
gen a enforce 1111aaaa h1.example.com >/dev/null
FAKE_SYSTEMD_DIE_AFTER='boxen-check_a@1.service' run widen a 1
assert_eq "the killed ctl left its check copy" "active" "$(unit_state 'boxen-check_a@1.service')"
gen b enforce 3333cccc h2.example.com >/dev/null
run tighten b 1
assert_eq "another agent's tighten still passes its check" "0" "$RC"
assert_eq "the leftover check copy was stopped" "inactive" "$(unit_state 'boxen-check_a@1.service')"
assert_eq "and b serves" "yes" "$(listening b)"

echo "a ctl stopped with SIGTERM during a check stops its check copy"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
FAKE_SYSTEMD_DIE_AFTER='boxen-check_a@1.service' FAKE_SYSTEMD_DIE_SIGNAL=TERM run widen a 1
assert_eq "the ctl was stopped" "143" "$RC"
assert_eq "its check copy is stopped" "inactive" "$(unit_state 'boxen-check_a@1.service')"

echo "remove stops the agent's check copies"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
FAKE_SYSTEMD_DIE_AFTER='boxen-check_a@1.service' run widen a 1
run remove a
assert_eq "remove succeeds" "0" "$RC"
assert_eq "the check copy is stopped" "inactive" "$(unit_state 'boxen-check_a@1.service')"

echo "a tighten cut short after the new generation starts"
serving_wide
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run tighten a 2
assert_eq "the old, wider generation still runs" "draining" "$(unit_state 'boxen-gen_a@1.service')"
assert_eq "status doesn't call it settled" "stopping" "$(listening a)"
assert_eq "and still shows the policy it moved to" "2222bbbb" "$(ctl status a | cut -f4)"
# The host sees stopping, not yes, so it tightens again.
gen a enforce 2222bbbb h1.example.com >/dev/null
run tighten a 3
assert_eq "the next tighten goes through" "0" "$RC"
assert_eq "it stops what the first one left" "3" "$(active_gens a)"
assert_eq "and status is settled" "yes" "$(listening a)"

echo "a widen finishes a tighten that was cut short"
serving_wide
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run tighten a 2
gen a enforce 3333cccc h1.example.com h3.example.com >/dev/null
run widen a 3
assert_eq "the widen goes through" "0" "$RC"
assert_contains "it says what it stopped" "a/1: an earlier change didn't finish; stopping it now" "$OUT"
assert_eq "the wider generation is stopped, not draining" "inactive" "$(unit_state 'boxen-gen_a@1.service')"
assert_eq "status is settled" "yes" "$(listening a)"

echo "boot finishes a tighten that was cut short"
serving_wide
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run tighten a 2
ctl boot 2>/dev/null
assert_eq "boot stops the old generation" "2" "$(active_gens a)"
assert_eq "status is settled" "yes" "$(listening a)"
serving_wide
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run tighten a 2
reboot
ctl boot
assert_eq "after a reboot only the new generation starts" "2" "$(active_gens a)"
assert_eq "and the record of the cut-short tighten is gone" "yes" "$(listening a)"

echo "a widen cut short after the new generation starts"
# Found by tests/property_test.sh: the new generation accepted next to the
# current one while status said yes, so going back to the current policy
# looked unchanged and the wider list stayed open.
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
gen a enforce 2222bbbb h1.example.com wide.example.com >/dev/null
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run widen a 2
assert_eq "the wider generation runs next to the current one" "1 2" "$(active_gens a)"
assert_eq "current hasn't moved" "1" "$(ctl status a | cut -f3)"
assert_eq "status doesn't call it settled" "stopping" "$(listening a)"
gen a enforce 1111aaaa h1.example.com >/dev/null
run tighten a 3
assert_eq "the host's next tighten goes through" "0" "$RC"
assert_eq "and stops it" "3" "$(active_gens a)"
assert_eq "status is settled" "yes" "$(listening a)"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
gen a enforce 2222bbbb h1.example.com wide.example.com >/dev/null
FAKE_SYSTEMD_DIE_AFTER='boxen-gen_a@2.service' run widen a 2
gen a enforce 3333cccc h1.example.com wide.example.com h3.example.com >/dev/null
run widen a 3
assert_eq "a later widen goes through" "0" "$RC"
assert_eq "and stops it, not just drains it" "inactive" "$(unit_state 'boxen-gen_a@2.service')"
assert_eq "the one that was current drains" "draining" "$(unit_state 'boxen-gen_a@1.service')"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
gen a enforce 2222bbbb h1.example.com wide.example.com >/dev/null
FAKE_SYSTEMD_NO_ACK='boxen-gen_a@2.service' FAKE_SYSTEMD_STUCK='boxen-gen_a@2.service' run widen a 2
assert_eq "a widen that never acks and won't stop fails" "1" "$RC"
assert_eq "status says stopping while it runs" "stopping" "$(listening a)"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
gen a enforce 2222bbbb h1.example.com wide.example.com >/dev/null
FAKE_SYSTEMD_START_FAIL='boxen-gen_a@2.service' run widen a 2
assert_eq "a widen that doesn't start fails" "1" "$RC"
assert_eq "and leaves status settled" "yes" "$(listening a)"
assert_eq "with no record left" "no" "$([[ -f "$S/etc/agents/a/stopping" ]] && echo yes || echo no)"

echo "a tighten whose old generation won't stop"
serving_wide
FAKE_SYSTEMD_STUCK='boxen-gen_a@1.service' run tighten a 2
assert_eq "fails" "1" "$RC"
assert_contains "says the new one serves and what's left" "it serves, but old generations still run: 1" "$OUT"
assert_eq "status agrees it isn't settled" "stopping" "$(listening a)"
gen a enforce 2222bbbb h1.example.com >/dev/null
run tighten a 3
assert_eq "once it stops, the retry settles" "yes" "$(listening a)"

echo "widen --force"
fresh
ctl add a 4750
for i in 1 2 3 4 5 6 7; do
  gen a enforce "1111aaa$i" h1.example.com "h$i.example.com" >/dev/null
  ctl widen a "$i"
done
assert_eq "six generations drain" "1 2 3 4 5 6 7" "$(active_gens a)"
gen a enforce 1111aaa8 h1.example.com h8.example.com >/dev/null
run widen a 8
assert_contains "a seventh draining one is refused" "still draining" "$OUT"
FAKE_CURL_LATE=1 run widen a 8 --force
assert_contains "a failed check says nothing changed" "the check failed; nothing changed" "$OUT"
assert_eq "and the oldest one still drains" "1 2 3 4 5 6 7" "$(active_gens a)"
run widen a 8 --force
assert_eq "a passing check makes room" "0" "$RC"
assert_eq "by ending the oldest one" "2 3 4 5 6 7 8" "$(active_gens a)"

echo "the probe's own hostname"
fresh
ctl add a 4750
OUT="$(gen a enforce 1234abcd boxen-probe.invalid 2>&1)" && RC=0 || RC=$?
assert_eq "an allowlist with it is refused" "1" "$RC"
assert_contains "and says why" "boxen-probe.invalid is reserved for the proxy's own check" "$OUT"
OUT="$(gen a enforce 1234abcd '*.probe.invalid' 2>&1)" && RC=0 || RC=$?
assert_eq "a wildcard that doesn't cover it is fine" "0" "$RC"

echo "log after the agent is removed and added again"
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
# Added an hour ago; it logged a decision ten minutes ago.
echo "$(( $(date +%s) - 3600 ))000000" > "$S/etc/agents/a/born"
old_usec="$(( $(date +%s) - 600 ))000000"
printf '%s\t%s\t%s\n' 'boxen-gen_a@1.service' "$old_usec" \
  '{"msg":"CANONICAL-PROXY-DECISION","allow":false,"decision_reason":"default rule policy used","requested_host":"old-agent.example.com:443","time":"t0"}' \
  >> "$FAKE_SYSTEMD/journal"
assert_contains "the agent's own log has its record" "old-agent.example.com" "$(ctl log a)"
ctl remove a
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
printf '%s\t%s\t%s\n' 'boxen-gen_a@1.service' "$(date +%s)000000" \
  '{"msg":"CANONICAL-PROXY-DECISION","allow":true,"decision_reason":"rule","requested_host":"new-agent.example.com:443","time":"t1"}' \
  >> "$FAKE_SYSTEMD/journal"
log="$(ctl log a)"
assert_contains "the new agent's log has its own record" "new-agent.example.com" "$log"
assert_not_contains "but not the removed agent's" "old-agent.example.com" "$log"
assert_not_contains "nor the probe's" "boxen-probe.invalid" "$log"

echo "gen keeps the current generation while it isn't running"
# After a reboot nothing runs until boot, and gen may run first; the ten-
# newest rule alone would delete current, and boot would have nothing to start.
fresh
ctl add a 4750
gen a enforce 1111aaaa h1.example.com >/dev/null
ctl widen a 1
reboot
for i in 1 2 3 4 5 6 7 8 9 10 11; do gen a enforce 2222bbbb h1.example.com >/dev/null; done
assert_eq "its directory is kept" "yes" "$([[ -d "$S/etc/agents/a/gens/1" ]] && echo yes || echo no)"
assert_eq "an older one that isn't current is not" "no" "$([[ -d "$S/etc/agents/a/gens/2" ]] && echo yes || echo no)"
ctl boot
assert_eq "boot starts it" "1" "$(active_gens a)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
