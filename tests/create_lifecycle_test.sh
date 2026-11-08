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

# Resolved, as boxen.create resolves the workspace (macOS: /var is /private/var).
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
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

# ===========================================================================
echo "the build's record"
# ===========================================================================
bxn() { { bash "$SANDBOX/repo/bxn" "$@" 2>&1 || true; } | sed 's/\x1b\[[0-9;]*m//g'; }
# A plugin that kills its bxn create, as SIGKILL, the OOM killer or a power
# cut would: no trap runs. Another that asks for a host bxn refuses.
cat > "$SANDBOX/repo/plugins/10-die.sh" <<'EOF'
PLUGIN_ID="die"; PLUGIN_NAME="Die"; PLUGIN_DESC="kills the build"; PLUGIN_DEFAULT=0; PLUGIN_CLI_FLAGS="--die"
plugin_install() { kill -KILL $$; }
EOF
cat > "$SANDBOX/repo/plugins/10-badhost.sh" <<'EOF'
PLUGIN_ID="badhost"; PLUGIN_NAME="Bad host"; PLUGIN_DESC="a host bxn refuses"; PLUGIN_DEFAULT=0; PLUGIN_CLI_FLAGS="--badhost"
PLUGIN_EGRESS_ALLOW="not_a_host!"
plugin_install() { :; }
EOF

fresh
create --name ok --no-tui --egress off
assert_eq "a finished build: succeeds" "0" "$RC"
assert_eq "a finished build: recorded done" "done" "$(cfg ok user.boxen.build)"
assert_contains "a finished build: its builder was recorded at init" "user.boxen.builder=" "$(grep '^init ' <<< "$(calls)")"
assert_contains "a finished build: …with the run's own tag" "user.boxen.build.run=" "$(grep '^init ' <<< "$(calls)")"

fresh
create --name lk --no-tui
assert_eq "a finished locked build: recorded done" "done" "$(cfg lk user.boxen.build)"

fresh
create --name half --no-tui --egress off --die
assert_eq "egress off, killed: the build stops" "137" "$RC"
assert_eq "egress off, killed: the record says it never finished" "running" "$(cfg half user.boxen.build)"
assert_contains "egress off, killed: doctor reports it" "half's build didn't finish" "$(bxn doctor)"
incus stop half
out="$(bxn half)"
assert_contains "egress off, killed: bxn <name> won't start it" "half's build didn't finish, so bxn won't start it" "$out"
assert_eq "egress off, killed: …and doesn't" "STOPPED" "$(status half)"
assert_contains "egress off, killed: nor will bxn -e" "half's build didn't finish" "$(bxn -e half FOO </dev/null)"
assert_eq "egress off, killed: …and doesn't" "STOPPED" "$(status half)"

# Before its lock: running, open, with the mode recorded but no proxy.
fresh
create --name open --no-tui --die
assert_eq "locked build killed before its lock: it's left running" "RUNNING" "$(status open)"
assert_eq "locked build killed before its lock: no proxy yet" "" "$(cfg open user.boxen.egress.container)"
assert_contains "…doctor reports it" "open's build didn't finish" "$(bxn doctor)"
assert_contains "…bxn egress ls lists it" "build abandoned (open)" "$(bxn egress ls)"
assert_contains "…bxn egress ls open says so" "abandoned before its allowlist was locked" "$(bxn egress ls open)"
out="$(bxn egress refresh --all)"
assert_contains "…bxn egress refresh --all stops it" "open's build was abandoned (open); it's stopped" "$out"
assert_eq "…and it is" "STOPPED" "$(status open)"

fresh
create --name open2 --no-tui --die
out="$(bxn egress refresh open2)"
assert_contains "…bxn egress refresh <name> stops it too" "open2's build was abandoned (open); it's stopped" "$out"
assert_eq "…and it is" "STOPPED" "$(status open2)"

fresh
create --name open3 --no-tui --die
FAKE_INCUS_FAIL_CALL='^stop open3' bash "$SANDBOX/repo/bxn" egress refresh open3 >"$SANDBOX/out2" 2>&1 && rc=0 || rc=$?
assert_eq "…one that won't stop: refresh fails" "1" "$rc"
assert_contains "…saying how to stop it" "incus stop --force open3" "$(cat "$SANDBOX/out2")"

fresh
FAKE_INCUS_FAIL_CALL='^list user.managed-by' bash "$SANDBOX/repo/bxn" egress ls >"$SANDBOX/out2" 2>&1 && rc=0 || rc=$?
assert_eq "bxn egress ls when Incus won't list: fails, not an empty table" "1" "$rc"

# The last step fails after the allowlist's own record says done.
fresh
FAKE_INCUS_FAIL_EXEC='shims=' create --name sh1 --no-tui
assert_eq "the shims step fails: the build fails" "1" "$RC"
assert_eq "the shims step fails: the record doesn't say done" "running" "$(cfg sh1 user.boxen.build)"
assert_contains "the shims step fails: doctor reports it" "sh1's build didn't finish" "$(bxn doctor)"

# A template launch kept after a failure before its card was locked.
fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
create --name tl --from base --no-tui --badhost
assert_eq "template launch fails before its lock: the build fails" "1" "$RC"
assert_eq "…it was never started" "STOPPED" "$(status tl)"
assert_eq "…its allowlist isn't recorded as locked" "open" "$(cfg tl user.boxen.egress.build)"
out="$(bxn -ua)"
assert_not_contains "…bxn -ua doesn't start it" "Starting tl" "$out"
assert_eq "…and it stays stopped" "no" "$(grep -qx 'start tl' <<< "$(calls)" && echo yes || echo no)"
assert_contains "…bxn <name> won't start it" "tl's build didn't finish, so bxn won't start it" "$(bxn tl)"
assert_eq "…and it stays stopped" "no" "$(grep -qx 'start tl' <<< "$(calls)" && echo yes || echo no)"

fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
create --name tl2 --from base --no-tui
assert_eq "a template launch that works: recorded locked, then done" "done done" "$(cfg tl2 user.boxen.egress.build) $(cfg tl2 user.boxen.build)"

# ===========================================================================
echo "a signal while incus init runs"
# ===========================================================================
# Bash runs the trap once init returns, which it does having made the container.
mkdir -p "$SANDBOX/slow"
cat > "$SANDBOX/slow/incus" <<EOF
#!/bin/bash
if [[ "\$1" == init ]]; then touch "\$FAKE_INCUS_STATE/initing"; sleep 2; fi
exec "$SANDBOX/bin/incus" "\$@"
EOF
chmod +x "$SANDBOX/slow/incus"
for sig in TERM HUP; do
  fresh
  PATH="$SANDBOX/slow:$PATH" bash "$SANDBOX/repo/boxen.create" --name s$sig --no-tui --egress off -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [[ -f "$FAKE_INCUS_STATE/initing" ]] && break; sleep 0.1; done
  kill -"$sig" "$pid"
  wait "$pid" && RC=0 || RC=$?
  OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$SANDBOX/out")"
  assert_eq "SIG$sig: the build stops" "$([[ $sig == TERM ]] && echo 143 || echo 129)" "$RC"
  assert_eq "SIG$sig: the container was made" "yes" "$(exists s$sig)"
  assert_contains "SIG$sig: and the run says so" "Container 's$sig' was partially created" "$OUT"
  assert_contains "SIG$sig: …and how to remove it" "bxn rm s$sig" "$OUT"
done

# Another run's container, under the name this run asked for: not ours.
fresh
incus init images:ubuntu/24.04 taken -c user.managed-by=boxen -c user.boxen.build.run=someone-else >/dev/null
create --name taken --no-tui --egress off
assert_eq "a name another run holds: refused" "1" "$RC"
assert_not_contains "a name another run holds: never offered for deletion" "partially created" "$OUT"
assert_eq "a name another run holds: it's still there" "yes" "$(exists taken)"
assert_eq "…with its own run's tag" "someone-else" "$(cfg taken user.boxen.build.run)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
