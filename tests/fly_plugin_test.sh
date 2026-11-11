#!/bin/bash
# tests/fly_plugin_test.sh
# The Fly CLI plugin installs a pinned flyctl release into the instance user's
# ~/.local/bin, with a fly link to it: the asset for the instance's
# architecture, checked against the pinned checksum, with nothing left behind
# in its temp directory. It names the hosts flyctl needs under the egress
# allowlist, and its login. Runs the
# real plugin against the fake `incus`, whose `su` runs the install script for
# real, with stand-ins for uname, curl and mktemp.
# Run: bash tests/fly_plugin_test.sh

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
mkdir -p "$SANDBOX/bin" "$SANDBOX/tmp"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"

# The fake runs `su` with a bare environment, so the stand-ins find the
# sandbox through paths written into them.
# uname -m reports the architecture in $SANDBOX/arch.
cat > "$SANDBOX/bin/uname" <<EOF
#!/bin/sh
if [ "\$1" = -m ]; then cat "$SANDBOX/arch"; else exec /usr/bin/uname "\$@"; fi
EOF
# curl logs its arguments and "downloads" the fixture to its -o path, or fails
# when $SANDBOX/curl-fail exists.
cat > "$SANDBOX/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >> "$SANDBOX/curl.log"
[ -f "$SANDBOX/curl-fail" ] && { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then out="\$2"; shift 2; else shift; fi
done
cp "$SANDBOX/fixture.tar.gz" "\$out"
EOF
# mktemp -d makes its directory in the sandbox and records it, so a test can
# check it's gone afterwards.
cat > "$SANDBOX/bin/mktemp" <<EOF
#!/bin/sh
d="$SANDBOX/tmp/flyctl.\$\$"
mkdir -p "\$d"
echo "\$d" >> "$SANDBOX/mktemp.log"
echo "\$d"
EOF
# install fails part way through the copy, leaving a partial file, when
# $SANDBOX/install-fail exists.
cat > "$SANDBOX/bin/install" <<EOF
#!/bin/sh
if [ -f "$SANDBOX/install-fail" ]; then
  for a in "\$@"; do last="\$a"; done
  echo partial > "\$last"
  echo "install: error writing '\$last': No space left on device" >&2
  exit 1
fi
exec /usr/bin/install "\$@"
EOF
# macOS before sha256sum: shasum takes the same -c --status.
if ! command -v sha256sum >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$SANDBOX/bin/sha256sum"
fi
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"

# A release tarball laid out like flyctl's: the binary alone, with a stray
# file beside it so a test can see only the binary is taken.
# <name> <binary body>; curl hands out whichever was made last.
make_fixture() {
  local d="$SANDBOX/fixture-$1"
  mkdir -p "$d"
  printf '#!/bin/sh\n%s\n' "$2" > "$d/flyctl"
  chmod +x "$d/flyctl"
  echo stray > "$d/README.md"
  tar -C "$d" -czf "$SANDBOX/fixture.tar.gz" README.md flyctl
  FIXTURE_BIN="$d/flyctl"
  FIXTURE_SUM="$(sha256sum "$SANDBOX/fixture.tar.gz" | cut -d' ' -f1)"
}
make_fixture good 'echo "fake flyctl $* no-update-check=${FLY_NO_UPDATE_CHECK:-}"'
WRONG_SUM="0000000000000000000000000000000000000000000000000000000000000000"

# The plugin, with the globals and helpers boxen.create gives it.
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
# shellcheck source=../plugins/50-fly.sh
source "$REPO_ROOT/plugins/50-fly.sh"
CONTAINER_NAME=box HOST_USER=dev
PINNED_X86_64="$FLY_SHA256_X86_64"
PINNED_ARM64="$FLY_SHA256_ARM64"

echo "defaults"
assert_eq "Fly is opt-in"                 "0"                "$PLUGIN_DEFAULT"
assert_eq "…with flags to opt in"         "--fly --flyctl"   "$PLUGIN_CLI_FLAGS"
assert_eq "id"                            "fly"              "$PLUGIN_ID"
assert_eq "the user logs in"              "fly auth login"   "$PLUGIN_LOGIN_COMMAND"
assert_eq "egress: Fly's API, the Machines API, the registry and Depot's API" \
  "api.fly.io api.machines.dev registry.fly.io api.depot.dev" "${PLUGIN_EGRESS_ALLOW:-}"
for host in $PLUGIN_EGRESS_ALLOW; do
  assert_eq "$host is a single host, not a wildcard" "yes" \
    "$([[ "$host" =~ ^[a-z0-9.-]+$ ]] && echo yes || echo no)"
done
# The download needs nothing beyond the baseline.
assert_eq "github.com is in the egress baseline" "yes" \
  "$(grep -qx 'github.com' "$REPO_ROOT/egress/baseline.txt" && echo yes || echo no)"
assert_eq "*.githubusercontent.com is in the egress baseline" "yes" \
  "$(grep -qxF '*.githubusercontent.com' "$REPO_ROOT/egress/baseline.txt" && echo yes || echo no)"
assert_eq "the version is pinned" "yes" \
  "$([[ "$FLY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo yes || echo no)"
assert_eq "the x86_64 checksum is pinned" "yes" \
  "$([[ "$PINNED_X86_64" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)"
assert_eq "the arm64 checksum is pinned"  "yes" \
  "$([[ "$PINNED_ARM64" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)"
assert_eq "the two checksums differ" "yes" \
  "$([[ "$PINNED_X86_64" != "$PINNED_ARM64" ]] && echo yes || echo no)"

# A fresh box on <arch>; the checksum for that arch matches the fixture and the
# other doesn't, so a success shows the right one was checked.
fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_EXEC FAKE_INCUS_FAIL_CALL
  echo "$1" > "$SANDBOX/arch"
  rm -f "$SANDBOX/curl.log" "$SANDBOX/mktemp.log" "$SANDBOX/curl-fail" "$SANDBOX/install-fail"
  rm -rf "$SANDBOX/tmp"; mkdir -p "$SANDBOX/tmp"
  FLY_SHA256_X86_64="$WRONG_SUM" FLY_SHA256_ARM64="$WRONG_SUM"
  incus launch images:ubuntu/24.04 box
}
run_install() { plugin_install > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }
installed() { plugin_is_installed && echo yes || echo no; }
bin()      { echo "$FAKE_INCUS_STATE/instances/box/root/home/dev/.local/bin/flyctl"; }
has_bin()  { [[ -x "$(bin)" ]] && echo yes || echo no; }
# The fly link: its target, or "none".
link()     { local l; l="$(dirname "$(bin)")/fly"; [[ -L "$l" ]] && readlink "$l" || echo none; }
# The staging file the binary is renamed from.
staged()   { [[ -e "$(dirname "$(bin)")/.flyctl.new" ]] && echo present || echo gone; }
curls()    { cat "$SANDBOX/curl.log" 2>/dev/null || true; }
execs()    { cat "$FAKE_INCUS_STATE/exec.log" 2>/dev/null || true; }
script()   { cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null || true; }
# Temp directories mktemp made that are still there.
leftovers() {
  local d n=0
  while read -r d; do [[ -e "$d" ]] && n=$((n+1)); done < <(cat "$SANDBOX/mktemp.log" 2>/dev/null || true)
  echo "$n"
}
made_tmp() { [[ -s "$SANDBOX/mktemp.log" ]] && echo yes || echo no; }
RELEASES="https://github.com/superfly/flyctl/releases/download"

# ===========================================================================
echo "x86_64"
# ===========================================================================
fresh_box x86_64
FLY_SHA256_X86_64="$FIXTURE_SUM"
assert_eq "before: not installed" "no" "$(installed)"
run_install
assert_eq "x86_64: succeeds" "0" "$RC"
assert_contains "x86_64: says which version" "Installing flyctl $FLY_VERSION" "$OUT"
assert_contains "x86_64: runs as the instance user, not root" "box :: su - dev -s /bin/bash" "$(execs)"
assert_not_contains "x86_64: no sudo" "sudo" "$(script)"
assert_contains "x86_64: the version goes in as an assignment" "FLY_VERSION=$FLY_VERSION" "$(script)"
assert_contains "x86_64: downloads the x86_64 asset of the pinned release" \
  "$RELEASES/v$FLY_VERSION/flyctl_${FLY_VERSION}_Linux_x86_64.tar.gz" "$(curls)"
assert_contains "x86_64: curl fails on an HTTP error" "-fSL" "$(curls)"
assert_eq "x86_64: the binary is in ~/.local/bin" "yes" "$(has_bin)"
assert_eq "x86_64: it's the one from the release" "$(cat "$FIXTURE_BIN")" "$(cat "$(bin)" 2>/dev/null)"
assert_eq "x86_64: only the binary and the link are installed" "fly flyctl" \
  "$(ls "$(dirname "$(bin)")" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
assert_eq "x86_64: fly links to flyctl, by a relative name" "flyctl" "$(link)"
assert_contains "x86_64: runs it to check, without an update check" \
  "fake flyctl version no-update-check=1" "$OUT"
assert_eq "x86_64: plugin_is_installed sees it" "yes" "$(installed)"
assert_eq "x86_64: no staging file left" "gone" "$(staged)"
assert_eq "x86_64: used a temp directory" "yes" "$(made_tmp)"
assert_eq "x86_64: the temp directory is removed" "0" "$(leftovers)"

# A second run (a rebuild, or a template that already has it) replaces it.
run_install
assert_eq "again: succeeds" "0" "$RC"
assert_eq "again: still installed" "yes" "$(has_bin)"
assert_eq "again: no temp directory left" "0" "$(leftovers)"
assert_eq "again: fly still links to flyctl" "flyctl" "$(link)"

# The binary without its link (a build stopped between the two) isn't
# installed, so a rebuild finishes it.
rm "$(dirname "$(bin)")/fly"
assert_eq "no link: has the binary" "yes" "$(has_bin)"
assert_eq "no link: plugin_is_installed says no" "no" "$(installed)"
run_install
assert_eq "no link: a rebuild succeeds" "0" "$RC"
assert_eq "no link: and puts the link back" "flyctl" "$(link)"
assert_eq "no link: plugin_is_installed sees it" "yes" "$(installed)"

# ===========================================================================
echo "arm64"
# ===========================================================================
for machine in aarch64 arm64; do
  fresh_box "$machine"
  FLY_SHA256_ARM64="$FIXTURE_SUM"
  run_install
  assert_eq "$machine: succeeds" "0" "$RC"
  assert_contains "$machine: downloads the arm64 asset" \
    "$RELEASES/v$FLY_VERSION/flyctl_${FLY_VERSION}_Linux_arm64.tar.gz" "$(curls)"
  assert_not_contains "$machine: not the x86_64 one" "x86_64" "$(curls)"
  assert_eq "$machine: installed" "yes" "$(has_bin)"
  assert_eq "$machine: the temp directory is removed" "0" "$(leftovers)"
done

# ===========================================================================
echo "an unsupported architecture"
# ===========================================================================
for machine in riscv64 armv7l i686; do
  fresh_box "$machine"
  FLY_SHA256_X86_64="$FIXTURE_SUM" FLY_SHA256_ARM64="$FIXTURE_SUM"
  run_install
  assert_eq "$machine: fails" "1" "$RC"
  assert_contains "$machine: says why" "flyctl: unsupported architecture: $machine" "$OUT"
  assert_eq "$machine: downloads nothing" "" "$(curls)"
  assert_eq "$machine: installs nothing" "no" "$(has_bin)"
  assert_eq "$machine: plugin_is_installed agrees" "no" "$(installed)"
done

# ===========================================================================
echo "a download that doesn't match the pinned checksum"
# ===========================================================================
fresh_box x86_64
FLY_SHA256_ARM64="$FIXTURE_SUM"   # the other arch's sum must not be used
run_install
assert_eq "mismatch: fails" "1" "$RC"
assert_contains "mismatch: says why" "flyctl: checksum mismatch for flyctl_${FLY_VERSION}_Linux_x86_64.tar.gz" "$OUT"
assert_eq "mismatch: installs nothing" "no" "$(has_bin)"
assert_eq "mismatch: the temp directory is removed" "0" "$(leftovers)"

# The real pinned sum, against a download that isn't the release.
fresh_box x86_64
FLY_SHA256_X86_64="$PINNED_X86_64"
run_install
assert_eq "pinned sum, other bytes: fails" "1" "$RC"
assert_eq "pinned sum, other bytes: installs nothing" "no" "$(has_bin)"

# ===========================================================================
echo "a failed download"
# ===========================================================================
fresh_box x86_64
FLY_SHA256_X86_64="$FIXTURE_SUM"
touch "$SANDBOX/curl-fail"
run_install
assert_eq "download fails: the plugin fails" "yes" "$([[ "$RC" -ne 0 ]] && echo yes || echo no)"
assert_contains "download fails: curl's error is shown" "404" "$OUT"
assert_eq "download fails: installs nothing" "no" "$(has_bin)"
assert_eq "download fails: the temp directory is removed" "0" "$(leftovers)"

# ===========================================================================
echo "a binary that doesn't run"
# ===========================================================================
GOOD_BIN="$FIXTURE_BIN"
make_fixture broken 'echo "cannot execute binary file" >&2; exit 126'
fresh_box x86_64
FLY_SHA256_X86_64="$FIXTURE_SUM"
run_install
assert_eq "won't run: the plugin fails" "yes" "$([[ "$RC" -ne 0 ]] && echo yes || echo no)"
assert_contains "won't run: its error is shown" "cannot execute binary file" "$OUT"
assert_eq "won't run: isn't installed, so a rebuild tries again" "no" "$(installed)"
assert_eq "won't run: no staging file" "gone" "$(staged)"
assert_eq "won't run: the temp directory is removed" "0" "$(leftovers)"

# Over a working install: the old binary stays.
fresh_box x86_64
make_fixture good 'echo "fake flyctl $* no-update-check=${FLY_NO_UPDATE_CHECK:-}"'
FLY_SHA256_X86_64="$FIXTURE_SUM"
run_install
assert_eq "upgrade to one that won't run: the first install succeeds" "0" "$RC"
make_fixture broken 'echo "cannot execute binary file" >&2; exit 126'
FLY_SHA256_X86_64="$FIXTURE_SUM"
run_install
assert_eq "upgrade to one that won't run: fails" "yes" "$([[ "$RC" -ne 0 ]] && echo yes || echo no)"
assert_eq "upgrade to one that won't run: the old binary stays" "$(cat "$GOOD_BIN")" "$(cat "$(bin)" 2>/dev/null)"
make_fixture good 'echo "fake flyctl $* no-update-check=${FLY_NO_UPDATE_CHECK:-}"'

# ===========================================================================
echo "a copy that fails part way"
# ===========================================================================
fresh_box x86_64
FLY_SHA256_X86_64="$FIXTURE_SUM"
touch "$SANDBOX/install-fail"
run_install
assert_eq "copy fails: the plugin fails" "1" "$RC"
assert_eq "copy fails: no partial binary where plugin_is_installed looks" "no" "$(installed)"
assert_eq "copy fails: the partial staging file is removed" "gone" "$(staged)"
assert_eq "copy fails: the temp directory is removed" "0" "$(leftovers)"

# ===========================================================================
echo "the instance can't be reached"
# ===========================================================================
fresh_box x86_64
FLY_SHA256_X86_64="$FIXTURE_SUM"
FAKE_INCUS_FAIL_CALL='^exec box' run_install
assert_eq "exec fails: the plugin fails" "1" "$RC"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
