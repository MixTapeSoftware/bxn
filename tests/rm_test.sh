#!/bin/bash
# tests/rm_test.sh
# bxn rm looks for work in the workspace that isn't pushed before deleting:
# changed or new files, commits on no remote, and stashes. Off a terminal it
# refuses when it finds some; on one it asks. When it can't tell (the
# container is stopped, or the check fails) it asks on a terminal and goes
# ahead off one. --force skips the check. Runs against the fake `incus`,
# with real git in a workspace inside the fake filesystem.
# Run: bash tests/rm_test.sh

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

command -v git >/dev/null || { echo "git is needed"; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
cp "$REPO_ROOT"/boxen.* "$REPO_ROOT"/bxn "$REPO_ROOT"/bxn.* "$SANDBOX/repo/"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export FAKE_INCUS_STATE="$SANDBOX/state"
export BOXEN_LOCK_DIR="$SANDBOX/state/lock"
export BOXEN_CONFIG_DIR="$SANDBOX/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

exists() { [[ -d "$FAKE_INCUS_STATE/instances/$1" ]] && echo yes || echo no; }
run() { OUT="$(bash "$SANDBOX/repo/bxn" "$@" 2>&1)" && RC=0 || RC=$?; }
# On a terminal, answering <answer> to any question.
run_tty() {
  local answer="$1"; shift
  OUT="$(printf '%s\n' "$answer" | TERM=dumb script -qec "bash $SANDBOX/repo/bxn $*" /dev/null 2>&1 | tr -d '\r')" && RC=0 || RC=$?
}
# A running container whose workspace is a git repository with one commit,
# which origin/main also has: nothing unpushed yet.
make_box() {
  local name="$1" ws
  incus launch img "$name" >/dev/null
  incus config set "$name" user.managed-by=boxen user.boxen=1
  ws="$(ws_of "$name")"
  mkdir -p "$ws"
  git -C "$ws" init -q -b main
  git -C "$ws" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
  git -C "$ws" update-ref refs/remotes/origin/main HEAD
}
ws_of() { echo "$FAKE_INCUS_STATE/instances/$1/root/workspace"; }
commit() { git -C "$(ws_of "$1")" -c user.name=t -c user.email=t@t commit -q --allow-empty -m more; }

echo "nothing unpushed"
make_box clean
run rm clean
assert_eq "it deletes" "0 no" "$RC $(exists clean)"
assert_not_contains "without a warning" "[!]" "$OUT"

echo "a changed file, off a terminal"
make_box dirty
echo hi > "$(ws_of dirty)/new.txt"
run rm dirty
assert_eq "it refuses" "1 yes" "$RC $(exists dirty)"
assert_contains "and says what it found" "dirty has work that isn't pushed: 1 changed or new file" "$OUT"
assert_contains "and how to delete anyway" "bxn rm --force dirty" "$OUT"

echo "--force"
run rm --force dirty
assert_eq "deletes without checking" "0 no" "$RC $(exists dirty)"
make_box dirty2
echo hi > "$(ws_of dirty2)/new.txt"
run rm dirty2 -f
assert_eq "-f after the name too" "0 no" "$RC $(exists dirty2)"

echo "commits on no remote, and stashes"
make_box ahead
commit ahead; commit ahead
git -C "$(ws_of ahead)" checkout -q -b side
commit ahead
run rm ahead
assert_eq "it refuses" "1 yes" "$RC $(exists ahead)"
assert_contains "it counts commits on every branch" "3 commits on no remote" "$OUT"
make_box stashed
echo hi > "$(ws_of stashed)/f"
git -C "$(ws_of stashed)" add f
git -C "$(ws_of stashed)" -c user.name=t -c user.email=t@t stash -q
run rm stashed
assert_eq "a stash is work too" "1 yes" "$RC $(exists stashed)"
assert_contains "and is counted" ": 1 stash" "$OUT"
assert_not_contains "the stashed file isn't counted as changed" "changed" "$OUT"

echo "on a terminal"
if command -v script >/dev/null 2>&1; then
  run_tty n rm ahead
  assert_eq "no keeps it" "yes" "$(exists ahead)"
  assert_contains "it asked" "Delete ahead anyway? [y/N]" "$OUT"
  assert_contains "and says so" "Nothing deleted" "$OUT"
  run_tty "" rm ahead
  assert_eq "enter keeps it" "yes" "$(exists ahead)"
  run_tty y rm ahead
  assert_eq "y deletes it" "no" "$(exists ahead)"
  make_box clean2
  run_tty n rm clean2
  assert_eq "nothing unpushed: no question" "no" "$(exists clean2)"
  assert_not_contains "none asked" "anyway" "$OUT"
else
  echo "  (skipped: no script command)"
fi

echo "a stopped container"
make_box stopped
echo hi > "$(ws_of stopped)/new.txt"
incus stop stopped
run rm stopped
assert_eq "off a terminal it deletes, as before" "0 no" "$RC $(exists stopped)"
assert_contains "with a note" "stopped isn't running, so bxn can't check it" "$OUT"
if command -v script >/dev/null 2>&1; then
  make_box stopped2
  incus stop stopped2
  run_tty n rm stopped2
  assert_eq "on a terminal it asks first" "yes" "$(exists stopped2)"
  assert_contains "saying why" "stopped2 isn't running" "$OUT"
fi

echo "the check fails"
make_box broken
echo hi > "$(ws_of broken)/new.txt"
FAKE_INCUS_FAIL_EXEC='^su ' run rm broken
assert_eq "off a terminal it deletes" "0 no" "$RC $(exists broken)"
assert_contains "with a note" "bxn couldn't check broken" "$OUT"

echo "not a git repository"
incus launch img plain >/dev/null
incus config set plain user.managed-by=boxen
mkdir -p "$(ws_of plain)"
echo hi > "$(ws_of plain)/f"
run rm plain
assert_eq "it deletes without asking" "0 no" "$RC $(exists plain)"
assert_not_contains "or a note" "[!]" "$OUT"

echo "a workspace somewhere else"
make_box elsewhere
incus config set elsewhere user.boxen.workspace=/home/me/code
mkdir -p "$FAKE_INCUS_STATE/instances/elsewhere/root/home/me"
mv "$(ws_of elsewhere)" "$FAKE_INCUS_STATE/instances/elsewhere/root/home/me/code"
echo hi > "$FAKE_INCUS_STATE/instances/elsewhere/root/home/me/code/f"
run rm elsewhere
assert_eq "it checks the recorded workspace" "1 yes" "$RC $(exists elsewhere)"

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
