#!/bin/bash
# tests/create_pickers_test.sh
# boxen.create's pickers without a terminal, and the cursor after Ctrl-C in
# one; plus the build's smaller edges: a dry run on macOS, which images are
# templates, an interrupt that a command took for itself, and the proxy URL
# handed to plugin_proxy hooks. Runs boxen.create end to end against the
# fake `incus`, with curl and git stubbed so nothing is downloaded.
# Run: bash tests/create_pickers_test.sh

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
cp "$REPO_ROOT"/boxen.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
echo hello > "$SANDBOX/ws/README"
# Two agents, the second marked default; one plugin, on by default.
cat > "$SANDBOX/repo/plugins/40-alpha.sh" <<'EOF'
PLUGIN_ID="alpha"; PLUGIN_NAME="Alpha"; PLUGIN_DESC="an agent"; PLUGIN_AGENT_COMMAND="alpha"
plugin_install() { :; }
EOF
cat > "$SANDBOX/repo/plugins/41-beta.sh" <<'EOF'
PLUGIN_ID="beta"; PLUGIN_NAME="Beta"; PLUGIN_DESC="an agent"; PLUGIN_AGENT_COMMAND="beta"; PLUGIN_DEFAULT=1
plugin_install() { :; }
EOF
cat > "$SANDBOX/repo/plugins/50-tool.sh" <<'EOF'
PLUGIN_ID="tool"; PLUGIN_NAME="Tool"; PLUGIN_DESC="a plugin"; PLUGIN_DEFAULT=1
plugin_install() { :; }
EOF

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
  mkdir -p "$FAKE_INCUS_STATE" "$BOXEN_CONFIG_DIR"
  # Asked once on a first create; answered already.
  echo builtin > "$BOXEN_CONFIG_DIR/plugins-source"
  unset FAKE_INCUS_FAIL_CALL FAKE_INCUS_FAIL_EXEC
}
plain() { sed $'s/\033\\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }
# create [args]: stdin as the caller gives it.
create() { bash "$SANDBOX/repo/boxen.create" "$@" -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(plain < "$SANDBOX/out")"; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null || true; }
calls() { cat "$FAKE_INCUS_STATE/calls.log" 2>/dev/null || true; }

# ===========================================================================
echo "the pickers without a terminal"
# ===========================================================================
fresh
create web --dry-run </dev/null
assert_eq "stdin from /dev/null: it goes ahead" "0" "$RC"
assert_contains "…and says why there were no pickers" "No terminal for the pickers" "$OUT"
assert_contains "…taking the default agent, as --no-tui does" "Agent:       Beta" "$OUT"
assert_contains "…and the default plugins" "[x] Tool" "$OUT"

# Keys a picker would act on: up to the other agent, Enter; space unticks.
fresh
printf 'k\n \n' | create web --dry-run
assert_eq "piped input: it goes ahead" "0" "$RC"
assert_contains "piped input: not taken for keystrokes" "Agent:       Beta" "$OUT"
assert_contains "…in either picker" "[x] Tool" "$OUT"

fresh
create web --dry-run --no-tui </dev/null
assert_not_contains "--no-tui: nothing to explain" "No terminal for the pickers" "$OUT"

# ===========================================================================
echo "Ctrl-C in a picker"
# ===========================================================================
# yes when the output hid the cursor, then showed it again after the last hide.
cursor_back() {
  local hid shown
  [[ "$1" == *$'\033[?25l'* && "$1" == *$'\033[?25h'* ]] || { echo no; return; }
  hid="${1%$'\033[?25l'*}"; shown="${1%$'\033[?25h'*}"
  if [[ ${#shown} -gt ${#hid} ]]; then echo yes; else echo no; fi
}
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
  # In a pseudo-terminal: the agent picker hides the cursor, then Ctrl-C.
  # The terminal's state is read right after, in the same terminal.
  fresh
  { sleep 1.5; printf '\003'; sleep 2; } |
    TERM=xterm timeout 60 script -qec "trap : INT; bash '$SANDBOX/repo/boxen.create' web --dry-run -p '$SANDBOX/ws'; echo rc=\$?; stty -a" /dev/null \
    > "$SANDBOX/tui.out" 2>&1 || true
  out="$(cat "$SANDBOX/tui.out")"
  assert_contains "the picker was up" "Pick the coding agent" "$(plain <<< "$out")"
  assert_contains "Ctrl-C ends the run" "rc=130" "$(plain <<< "$out")"
  back="$(cursor_back "$out")"
  assert_eq "the cursor is shown again after it" "yes" "$back"
  assert_contains "the terminal's settings were read after" "speed" "$(plain <<< "$out")"
  assert_not_contains "…and typing echoes again" " -echo " " $(plain <<< "$out" | tr '\n' ' ') "

  fresh
  { sleep 1.5; printf '\n'; sleep 1; printf '\003'; sleep 2; } |
    TERM=xterm timeout 60 script -qec "bash '$SANDBOX/repo/boxen.create' web --dry-run -p '$SANDBOX/ws'; echo rc=\$?" /dev/null \
    > "$SANDBOX/tui.out" 2>&1 || true
  out="$(cat "$SANDBOX/tui.out")"
  assert_contains "the plugin picker was up" "Select plugins to install" "$(plain <<< "$out")"
  back="$(cursor_back "$out")"
  assert_eq "Ctrl-C in the plugin picker: the cursor is shown again" "yes" "$back"
else
  echo "  skip: needs util-linux script(1)"
fi

# ===========================================================================
echo "a dry run on macOS"
# ===========================================================================
mkdir -p "$SANDBOX/mac"
printf '#!/bin/sh\necho Darwin\n' > "$SANDBOX/mac/uname"
# Colima with no boxen profile; every call logged.
printf '#!/bin/sh\necho "colima $*" >> "%s/colima.log"\nexit 0\n' "$SANDBOX" > "$SANDBOX/mac/colima"
chmod +x "$SANDBOX/mac/"*
fresh
rm -f "$SANDBOX/colima.log"
PATH="$SANDBOX/mac:$PATH" create web --dry-run --no-tui </dev/null
assert_eq "no Colima profile: the dry run ends well" "0" "$RC"
assert_eq "…without creating or starting one" "colima list" "$(sort -u "$SANDBOX/colima.log")"
assert_contains "…saying the real run would" "The real run would first create the Colima profile 'boxen'" "$OUT"
assert_eq "…and Incus isn't touched" "" "$(calls)"

printf '#!/bin/sh\necho "colima $*" >> "%s/colima.log"\n[ "$1" = list ] && echo "boxen  Stopped"\nexit 0\n' "$SANDBOX" > "$SANDBOX/mac/colima"
fresh
rm -f "$SANDBOX/colima.log"
PATH="$SANDBOX/mac:$PATH" create web --dry-run --no-tui </dev/null
assert_eq "a stopped profile: not started" "colima list" "$(sort -u "$SANDBOX/colima.log")"
assert_contains "…saying the real run would" "The real run would first start the Colima profile 'boxen'" "$OUT"

# Another profile whose name starts the same is running; boxen isn't.
printf '#!/bin/sh\necho "colima $*" >> "%s/colima.log"\n[ "$1" = list ] && printf "PROFILE STATUS\\nboxen2 Running\\nboxen Stopped\\n"\nexit 0\n' "$SANDBOX" > "$SANDBOX/mac/colima"
fresh
rm -f "$SANDBOX/colima.log"
PATH="$SANDBOX/mac:$PATH" create web --dry-run --no-tui </dev/null
assert_contains "boxen2 running, boxen stopped: boxen is taken as stopped" "The real run would first start the Colima profile 'boxen'" "$OUT"

# colima list itself fails: the dry run goes on, saying it would create it.
printf '#!/bin/sh\necho "colima $*" >> "%s/colima.log"\n[ "$1" = list ] && exit 1\nexit 0\n' "$SANDBOX" > "$SANDBOX/mac/colima"
fresh
rm -f "$SANDBOX/colima.log"
PATH="$SANDBOX/mac:$PATH" create web --dry-run --no-tui </dev/null
assert_eq "a failing colima list doesn't end the run" "0" "$RC"
assert_contains "…it says it would create the profile" "create the Colima profile 'boxen'" "$OUT"

# ===========================================================================
echo "which images are templates"
# ===========================================================================
fresh
create --name a --image ubuntu/24.04 --no-tui --egress off </dev/null
assert_eq "the help's old spelling of the default: refused" "1" "$RC"
assert_contains "…saying how to name the image server's" "images:ubuntu/24.04" "$OUT"

fresh
create --name b --image ubuntu:24.04 --no-tui --egress off </dev/null
assert_eq "another remote's image: builds" "0" "$RC"
assert_not_contains "…not as a template" "Using local template" "$OUT"
assert_contains "…but provisioned" "Installing packages" "$OUT"

fresh
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
create --name c --image incus-init/base --no-tui --egress off </dev/null
assert_contains "incus-init/NAME: a template" "Using local template: incus-init/base" "$OUT"
assert_not_contains "…not provisioned" "Installing packages" "$OUT"

assert_contains "the help gives the default as it's spelled" "default: images:ubuntu/24.04" "$(bash "$SANDBOX/repo/boxen.create" --help)"

# ===========================================================================
echo "an interrupt a command took for itself"
# ===========================================================================
# On a terminal, incus exec passes Ctrl-C to the command inside; the build
# sees only its exit code, 130.
cat > "$SANDBOX/repo/plugins/45-int.sh" <<'EOF'
PLUGIN_ID="int"; PLUGIN_NAME="Int"; PLUGIN_DESC="interrupted"; PLUGIN_CLI_FLAGS="--int"
plugin_install() { [ -t 0 ] && echo "hook stdin: a terminal"; exit 130; }
EOF
cat > "$SANDBOX/repo/plugins/60-after.sh" <<'EOF'
PLUGIN_ID="after"; PLUGIN_NAME="Zafter"; PLUGIN_DESC="sorted after"; PLUGIN_DEFAULT=1
plugin_install() { touch "$FAKE_INCUS_STATE/after-ran"; }
EOF
fresh
create --name i --no-tui --egress off --int </dev/null
assert_eq "a plugin interrupted: the build stops" "130" "$RC"
assert_eq "…no later plugin runs" "no" "$([[ -f "$FAKE_INCUS_STATE/after-ran" ]] && echo yes || echo no)"
assert_not_contains "…not reported as a failed plugin and passed over" "continuing with remaining plugins" "$OUT"
rm -f "$SANDBOX/repo/plugins/45-int.sh"

mkdir -p "$SANDBOX/int"
cat > "$SANDBOX/int/incus" <<EOF
#!/bin/bash
[[ "\$1" == exec && "\$*" == *"mise install"* ]] && exit 130
exec "$SANDBOX/bin/incus" "\$@"
EOF
chmod +x "$SANDBOX/int/incus"
mkdir -p "$SANDBOX/ws-mise"; echo '[tools]' > "$SANDBOX/ws-mise/mise.toml"
fresh
PATH="$SANDBOX/int:$PATH" bash "$SANDBOX/repo/boxen.create" --name m --no-tui --egress off -p "$SANDBOX/ws-mise" </dev/null >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?
OUT="$(plain < "$SANDBOX/out")"
assert_eq "mise install interrupted: the build stops" "130" "$RC"
assert_not_contains "…instead of a warning and Container ready" "Container ready" "$OUT"

fresh
mkdir -p "$SANDBOX/fail"
sed 's/exit 130/exit 1/' "$SANDBOX/int/incus" > "$SANDBOX/fail/incus"; chmod +x "$SANDBOX/fail/incus"
PATH="$SANDBOX/fail:$PATH" bash "$SANDBOX/repo/boxen.create" --name m2 --no-tui --egress off -p "$SANDBOX/ws-mise" </dev/null >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?
OUT="$(plain < "$SANDBOX/out")"
assert_eq "mise install fails: the build still finishes" "0" "$RC"
assert_contains "…with a warning" "mise install failed" "$OUT"

# ===========================================================================
echo "the proxy URL for plugin_proxy hooks"
# ===========================================================================
# A locked plugin loses the container's port record; another keeps its own
# proxy setting, and records what it's given.
cat > "$SANDBOX/repo/plugins/70-lose.sh" <<'EOF'
PLUGIN_ID="lose"; PLUGIN_NAME="Lose"; PLUGIN_DESC="x"; PLUGIN_PHASE=locked; PLUGIN_CLI_FLAGS="--lose"
plugin_install() { incus config unset "$CONTAINER_NAME" user.boxen.egress.port; }
EOF
cat > "$SANDBOX/repo/plugins/70-own.sh" <<'EOF'
PLUGIN_ID="own"; PLUGIN_NAME="Own"; PLUGIN_DESC="x"; PLUGIN_CLI_FLAGS="--own"
plugin_is_installed() { :; }
plugin_install() { :; }
plugin_proxy() { echo "url=[$PROXY_URL]" >> "$FAKE_INCUS_STATE/proxy-hook"; }
EOF
fresh
create --name p --no-tui --own </dev/null
assert_eq "a good URL: the hook gets it" "url=[http://10.201.0.11:10000]" "$(cat "$FAKE_INCUS_STATE/proxy-hook" 2>/dev/null)"

fresh
create --name p2 --no-tui --own --lose </dev/null
assert_eq "no URL to be had: the build fails" "1" "$RC"
assert_contains "…saying why" "Could not work out p2's proxy address" "$OUT"
assert_eq "…and the hook never hears 'remove the proxy settings'" "" "$(cat "$FAKE_INCUS_STATE/proxy-hook" 2>/dev/null || true)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
