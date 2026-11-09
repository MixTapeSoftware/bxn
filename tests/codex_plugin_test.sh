#!/bin/bash
# tests/codex_plugin_test.sh
# Codex runs commands in bubblewrap, which Ubuntu's kernel stops from using
# user namespaces unless an AppArmor profile allows it. The plugin loads one
# in a VM, on install and on every launch from a template, and nowhere else.
# It also lets those commands use the network, which Codex's sandbox cuts off
# by default, unless the user's config already says otherwise.
# Runs the plugin's guest script for real, against stubs for
# systemd-detect-virt and apparmor_parser, and its hooks against the fake
# `incus`.
# Run: bash tests/codex_plugin_test.sh

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

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/guest-bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"

# The plugin, with the globals and helpers boxen.create gives it.
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
# shellcheck source=../plugins/50-codex.sh
source "$REPO_ROOT/plugins/50-codex.sh"
CONTAINER_NAME=box HOST_USER=dev

echo "hooks"
assert_eq "it runs on launch from a template" "1" "$PLUGIN_RUN_ON_LAUNCH"
assert_contains "launching loads the profile" "codex_bwrap_profile" "$(declare -f plugin_on_launch)"
assert_contains "launching turns the network on" "codex_network_access" "$(declare -f plugin_on_launch)"
install_body="$(declare -f plugin_install)"
assert_contains "installing loads the profile" "codex_bwrap_profile" "$install_body"
# After Codex is installed, so its config directory belongs to the user.
after_npm="${install_body#*@openai/codex}"
assert_contains "installing turns the network on, after installing Codex" "codex_network_access" "$after_npm"
# After bubblewrap is installed, since the script skips a missing bwrap.
before_profile="${install_body%%codex_bwrap_profile*}"
assert_contains "…after installing bubblewrap" "apt-get install -y bubblewrap" "$before_profile"

export FAKE_INCUS_STATE="$SANDBOX/state"
mkdir -p "$FAKE_INCUS_STATE"
incus launch images:ubuntu/24.04 box >/dev/null
out="$(plugin_on_launch 2>&1)"
n="$(grep -n 'sh -s --' "$FAKE_INCUS_STATE/exec.log" | tail -n 1 | cut -d: -f1)"
assert_contains "it runs the script as root in the guest" \
  "box :: sh -s -- /proc/sys/kernel/apparmor_restrict_unprivileged_userns /etc/apparmor.d/bwrap /usr/bin/bwrap /sys/kernel/security/apparmor/profiles" \
  "$(sed -n "${n}p" "$FAKE_INCUS_STATE/exec.log")"
assert_eq "…sending the script on stdin" "$(printf '%s' "$CODEX_BWRAP_SCRIPT")" "$(cat "$FAKE_INCUS_STATE/exec-stdin/$n")"
assert_eq "…and says nothing when it works" "" "$out"
n="$(grep -n "su - dev -c sh -s" "$FAKE_INCUS_STATE/exec.log" | tail -n 1 | cut -d: -f1)"
assert_eq "the network setting is written as the user" "$(printf '%s' "$CODEX_NETWORK_SCRIPT")" "$(cat "$FAKE_INCUS_STATE/exec-stdin/$n")"
assert_contains "…into the user's Codex config" "network_access = true" \
  "$(cat "$FAKE_INCUS_STATE/instances/box/root/home/dev/.codex/config.toml")"
rc=0
out="$(FAKE_INCUS_FAIL_EXEC='^sh -s' plugin_on_launch 2>&1)" || rc=$?
assert_eq "a failure doesn't stop the build" "0" "$rc"
assert_contains "…but says what will break" "Failed RTM_NEWADDR" "$out"
rc=0
out="$(FAKE_INCUS_FAIL_EXEC='^su - dev' plugin_on_launch 2>&1)" || rc=$?
assert_eq "the network setting failing doesn't stop the build" "0" "$rc"
assert_contains "…but says what to set" "network_access = true" "$out"

# The network setting. Each case gets a fresh home.
H=""
home() { H="$SANDBOX/home-$RANDOM$RANDOM"; mkdir -p "$H"; }
run_net() { printf '%s' "$CODEX_NETWORK_SCRIPT" | HOME="$H" sh -s; }
cfg_of() { cat "$H/.codex/config.toml"; }

echo "network: no config"
home
rc=0; run_net || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "it writes the table and the key" "[sandbox_workspace_write]|network_access = true" \
  "$(grep -v '^#' "$H/.codex/config.toml" | paste -sd'|' -)"
assert_contains "…saying why" "# bxn: commands Codex runs may use the network" "$(cfg_of)"
before="$(cfg_of)"
run_net
assert_eq "a second run changes nothing" "$before" "$(cfg_of)"
assert_eq "…and leaves no temporary file" "config.toml" "$(ls "$H/.codex")"

echo "network: a config of the user's"
home; mkdir -p "$H/.codex"
printf 'model = "gpt-5"\n\n[profiles.fast]\nmodel = "gpt-5-mini"' > "$H/.codex/config.toml"
run_net
cfg="$(cfg_of)"
assert_eq "what was there stays first" 'model = "gpt-5"' "$(head -n 1 "$H/.codex/config.toml")"
assert_contains "…the last line too, though it had no newline" $'model = "gpt-5-mini"\n' "$cfg"
assert_contains "…and the table is added after it" $'[sandbox_workspace_write]\nnetwork_access = true' "$cfg"
home; mkdir -p "$H/.codex"
printf '[sandbox_workspace_write]\nnetwork_access = false\n' > "$H/.codex/config.toml"
run_net
assert_eq "network turned off by the user stays off" $'[sandbox_workspace_write]\nnetwork_access = false' "$(cfg_of)"
home; mkdir -p "$H/.codex"
printf '[sandbox_workspace_write]\nwritable_roots = ["/tmp"]\n' > "$H/.codex/config.toml"
run_net
assert_eq "a table of the user's, without the key, isn't touched" $'[sandbox_workspace_write]\nwritable_roots = ["/tmp"]' "$(cfg_of)"
home; mkdir -p "$H/.codex"
printf 'sandbox_workspace_write.network_access = false\n' > "$H/.codex/config.toml"
run_net
assert_eq "…nor a dotted key, which a second table would break" 'sandbox_workspace_write.network_access = false' "$(cfg_of)"

echo "network: a linked config"
home; mkdir -p "$H/.codex" "$H/dotfiles"
printf 'model = "gpt-5"\n' > "$H/dotfiles/codex.toml"
ln -s "$H/dotfiles/codex.toml" "$H/.codex/config.toml"
run_net
assert_eq "the link stays a link" "yes" "$([[ -L "$H/.codex/config.toml" ]] && echo yes || echo no)"
assert_contains "…and the file it points to gets the setting" "network_access = true" "$(cat "$H/dotfiles/codex.toml")"

echo "network: the config can't be written"
home; mkdir -p "$H/.codex"
printf 'model = "gpt-5"\n' > "$H/.codex/config.toml"
chmod 500 "$H/.codex"
rc=0; run_net 2>/dev/null || rc=$?
chmod 700 "$H/.codex"
if [[ $(id -u) -ne 0 ]]; then
  assert_eq "it fails" "1" "$((rc != 0))"
  assert_eq "…leaving the config as it was" 'model = "gpt-5"' "$(cfg_of)"
fi

# The guest script. Each case gets a fresh guest: the restriction's sysctl,
# a bwrap, and stubs that record what was loaded.
G=""
guest() {
  G="$SANDBOX/guest-$RANDOM$RANDOM"
  mkdir -p "$G/bin" "$G/apparmor.d/abstractions"
  echo 1 > "$G/restrict"
  printf 'usr.bin.man (enforce)\n' > "$G/profiles"
  printf 'profile man /usr/bin/man { }\n' > "$G/apparmor.d/usr.bin.man"
  printf '#!/bin/sh\n' > "$G/bwrap"; chmod +x "$G/bwrap"
  printf '#!/bin/sh\n[ "${GUEST_VIRT:-vm}" = vm ]\n' > "$G/bin/systemd-detect-virt"
  printf '#!/bin/sh\necho "$*" >> "%s/parser.args"\ncat >> "%s/loaded"\n[ -z "${GUEST_PARSER_FAIL:-}" ]\n' "$G" "$G" > "$G/bin/apparmor_parser"
  chmod +x "$G/bin/systemd-detect-virt" "$G/bin/apparmor_parser"
}
run_guest() {
  printf '%s' "$CODEX_BWRAP_SCRIPT" | PATH="$G/bin:$PATH" sh -s -- "$G/restrict" "$G/apparmor.d/bwrap" "$G/bwrap" "$G/profiles"
}

echo "guest: a VM with the restriction on"
guest
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "it replaces any loaded profile of that name" "-r" "$(cat "$G/parser.args")"
loaded="$(cat "$G/loaded")"
assert_contains "the profile is for bwrap" "profile bwrap $G/bwrap flags=(unconfined) {" "$loaded"
assert_contains "…and lets it use user namespaces" "  userns," "$loaded"
assert_contains "…under AppArmor 4's rules" "abi <abi/4.0>," "$loaded"
assert_eq "the same profile is kept for the next boot" "$loaded" "$(cat "$G/apparmor.d/bwrap")"
assert_contains "…marked as bxn's" "# bxn: codex plugin" "$(head -n 1 "$G/apparmor.d/bwrap")"
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "a second run replaces its own profile" "0:2" "$rc:$(grep -c . "$G/parser.args")"

echo "guest: nothing to do"
guest
GUEST_VIRT=container run_guest
assert_eq "a container loads nothing" "no:no" "$([[ -e "$G/loaded" ]] && echo yes || echo no):$([[ -e "$G/apparmor.d/bwrap" ]] && echo yes || echo no)"
guest; echo 0 > "$G/restrict"; run_guest
assert_eq "the restriction off: nothing loaded" "no" "$([[ -e "$G/loaded" ]] && echo yes || echo no)"
guest; rm "$G/restrict"; run_guest
assert_eq "a kernel without the restriction: nothing loaded" "no" "$([[ -e "$G/loaded" ]] && echo yes || echo no)"
guest; rm "$G/bwrap"; run_guest
assert_eq "no bwrap: nothing loaded" "no" "$([[ -e "$G/loaded" ]] && echo yes || echo no)"

echo "guest: someone else's profile"
guest
printf 'profile bwrap /usr/bin/bwrap { }\n' > "$G/apparmor.d/bwrap"
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "…without loading anything" "no" "$([[ -e "$G/loaded" ]] && echo yes || echo no)"
assert_eq "…leaving that profile as it was" "profile bwrap /usr/bin/bwrap { }" "$(cat "$G/apparmor.d/bwrap")"
assert_contains "…and says so" "not written by bxn" "$(cat "$G/err")"

echo "guest: another bwrap profile"
guest
printf 'abi <abi/4.0>,\n  profile bwrap /usr/bin/bwrap flags=(attach_disconnected) {\n  }\n' > "$G/apparmor.d/bwrap-userns-restrict"
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "one the distribution ships: it succeeds" "0" "$rc"
assert_eq "…without loading bxn's beside it" "no:no" "$([[ -e "$G/loaded" ]] && echo yes || echo no):$([[ -e "$G/apparmor.d/bwrap" ]] && echo yes || echo no)"
assert_contains "…and says which file has one" "bwrap-userns-restrict has a bwrap profile already" "$(cat "$G/err")"
guest
printf 'bwrap (enforce)\n' >> "$G/profiles"
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "one loaded from elsewhere: it succeeds" "0" "$rc"
assert_eq "…without replacing it" "no:no" "$([[ -e "$G/loaded" ]] && echo yes || echo no):$([[ -e "$G/apparmor.d/bwrap" ]] && echo yes || echo no)"
assert_contains "…and says so" "loaded already" "$(cat "$G/err")"
guest
run_guest
printf 'bwrap (unconfined)\n' >> "$G/profiles"
rc=0; run_guest 2>"$G/err" || rc=$?
assert_eq "bxn's own, loaded at boot: a later run replaces it" "0:2" "$rc:$(grep -c . "$G/parser.args")"

echo "guest: the profile doesn't load"
guest
rc=0; GUEST_PARSER_FAIL=1 run_guest 2>"$G/err" || rc=$?
assert_eq "it fails" "1" "$((rc != 0))"
assert_eq "…and writes nothing to load at boot" "no" "$([[ -e "$G/apparmor.d/bwrap" ]] && echo yes || echo no)"

echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
