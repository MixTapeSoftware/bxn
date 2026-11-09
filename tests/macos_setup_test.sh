#!/bin/bash
# tests/macos_setup_test.sh
# boxen.macos.setup starts its Colima profile with no folders from the Mac
# mounted (--mount none): when it creates the profile, and when it starts one
# that is stopped, which removes a mount an earlier bxn left. A running
# profile isn't restarted; if it mounts anything, the setup says so and how
# to remove it. Runs the real script against a fake uname, colima and incus.
# Run: bash tests/macos_setup_test.sh

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
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\necho Darwin\n' > "$SANDBOX/bin/uname"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/incus"
# Colima: `list` prints $FAKE_COLIMA_STATUS for the boxen profile (none when
# empty); `ssh` prints $FAKE_COLIMA_MOUNTS; `version` reports
# $FAKE_COLIMA_VERSION (default v0.10.0); every call is logged.
cat > "$SANDBOX/bin/colima" <<EOF
#!/bin/sh
echo "colima \$*" >> "$SANDBOX/colima.log"
case "\$1" in
  list) echo "PROFILE STATUS"; [ -n "\$FAKE_COLIMA_STATUS" ] && echo "boxen \$FAKE_COLIMA_STATUS" ;;
  ssh) [ -n "\$FAKE_COLIMA_MOUNTS" ] && printf '%b' "\$FAKE_COLIMA_MOUNTS" ;;
  version) echo "colima version \${FAKE_COLIMA_VERSION:-v0.10.0}"; echo "git commit: abc" ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"

# Sources the setup as boxen.create does, with its helpers.
setup() {
  rm -f "$SANDBOX/colima.log"
  OUT="$(bash -c 'set -euo pipefail
    log() { echo "[+] $1"; }; warn() { echo "[!] $1"; }; error() { echo "[ERROR] $1"; exit 1; }
    source "$1"' _ "$REPO_ROOT/boxen.macos.setup" 2>&1)" && RC=0 || RC=$?
  CALLS="$(grep -v '^colima list\|^colima version' "$SANDBOX/colima.log" 2>/dev/null || true)"
}

echo "no profile yet"
FAKE_COLIMA_STATUS="" FAKE_COLIMA_MOUNTS="" setup
assert_eq "it succeeds" "0" "$RC"
assert_eq "it creates the profile with no mounts" \
  "colima start --runtime incus --profile boxen --cpu 4 --memory 8 --disk 100 --mount none" "$CALLS"
assert_contains "and says so" "no folders from this Mac mounted" "$OUT"

echo "a stopped profile"
FAKE_COLIMA_STATUS=Stopped FAKE_COLIMA_MOUNTS="" setup
assert_eq "it starts it with no mounts" "colima start --profile boxen --mount none" "$CALLS"

echo "a Colima older than 0.10.0"
FAKE_COLIMA_VERSION=v0.9.1 FAKE_COLIMA_STATUS="" FAKE_COLIMA_MOUNTS="" setup
assert_eq "it creates the profile without the flag it would misread" \
  "colima start --runtime incus --profile boxen --cpu 4 --memory 8 --disk 100" "$CALLS"
assert_contains "and says to upgrade" "that takes Colima 0.10.0 or later" "$OUT"
assert_not_contains "it doesn't claim no mounts" "no folders from this Mac mounted" "$OUT"
FAKE_COLIMA_VERSION=v0.9.1 FAKE_COLIMA_STATUS=Stopped FAKE_COLIMA_MOUNTS="" setup
assert_eq "a stopped profile starts as before" "colima start --profile boxen" "$CALLS"
FAKE_COLIMA_VERSION=0.10.2 FAKE_COLIMA_STATUS=Stopped FAKE_COLIMA_MOUNTS="" setup
assert_eq "a version without the v counts" "colima start --profile boxen --mount none" "$CALLS"
FAKE_COLIMA_VERSION=v1.0.0 FAKE_COLIMA_STATUS=Stopped FAKE_COLIMA_MOUNTS="" setup
assert_eq "so does 1.0" "colima start --profile boxen --mount none" "$CALLS"
FAKE_COLIMA_VERSION=HEAD-abc FAKE_COLIMA_STATUS=Stopped FAKE_COLIMA_MOUNTS="" setup
assert_eq "a version it can't read is taken as old" "colima start --profile boxen" "$CALLS"

echo "a running profile with a mount"
FAKE_COLIMA_STATUS=Running FAKE_COLIMA_MOUNTS='/Users/me\n' setup
assert_eq "it succeeds" "0" "$RC"
assert_not_contains "it isn't restarted" "colima start" "$CALLS"
assert_contains "it looks in the VM" "colima ssh --profile boxen -- findmnt" "$CALLS"
assert_contains "it names the mount" "mounts folders from this Mac (/Users/me)" "$OUT"
assert_contains "and how to remove it" "colima stop -p boxen && colima start -p boxen --mount none" "$OUT"

FAKE_COLIMA_VERSION=v0.9.1 FAKE_COLIMA_STATUS=Running FAKE_COLIMA_MOUNTS='/Users/me\n' setup
assert_contains "with an old Colima, the fix starts with an upgrade" "brew upgrade colima, then colima stop -p boxen" "$OUT"

echo "a running profile with two"
FAKE_COLIMA_STATUS=Running FAKE_COLIMA_MOUNTS='/Users/me\n/tmp/colima\n' setup
assert_contains "it names both" "(/Users/me /tmp/colima)" "$OUT"

echo "a running profile without mounts"
FAKE_COLIMA_STATUS=Running FAKE_COLIMA_MOUNTS="" setup
assert_eq "it succeeds" "0" "$RC"
assert_not_contains "no warning" "[!]" "$OUT"

echo "what the VM prints"
FAKE_COLIMA_STATUS=Running FAKE_COLIMA_MOUNTS='/Users/me\033]0;title\007\n' setup
assert_not_contains "control characters don't reach the terminal" $'\033' "$OUT"

echo "the dry run"
FAKE_COLIMA_STATUS="" DRY_RUN=1 setup
assert_contains "says the profile will have no mounts" "100GB disk, no folders from this Mac mounted" "$OUT"
FAKE_COLIMA_STATUS=Stopped DRY_RUN=1 setup
assert_contains "and so will a stopped one" "start the Colima profile 'boxen', with no folders from this Mac mounted" "$OUT"
assert_eq "it starts nothing" "" "$CALLS"
FAKE_COLIMA_VERSION=v0.9.1 FAKE_COLIMA_STATUS="" DRY_RUN=1 setup
assert_contains "with an old Colima it says the home directory stays" "100GB disk, your home directory mounted" "$OUT"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
