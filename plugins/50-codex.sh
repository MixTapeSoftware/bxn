PLUGIN_ID="codex"
PLUGIN_NAME="Codex"
PLUGIN_DESC="OpenAI coding agent"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--codex"
PLUGIN_AGENT_COMMAND="codex"
# A template made before the bubblewrap profile or the network setting below
# gets them on launch.
PLUGIN_RUN_ON_LAUNCH=1

# Codex runs each command it's given inside bubblewrap. Ubuntu 23.10 and
# later let an unprivileged program create a user namespace but not use it
# (kernel.apparmor_restrict_unprivileged_userns=1) unless an AppArmor
# profile allows it, and Ubuntu 24.04 ships none for bubblewrap, so every
# command fails with "bwrap: loopback: Failed RTM_NEWADDR: Operation not
# permitted". A VM runs Ubuntu's kernel, restriction and all. A container
# shares the host's kernel and can't load profiles, so it's left alone.
#
# The profile lets bwrap, and nothing else, use user namespaces. It's loaded
# first and written to /etc/apparmor.d only once it loads, so a failure
# leaves nothing behind, and a success outlives a reboot. Any other bwrap
# profile is left as it is, and bxn's isn't loaded beside it: one at that
# path that bxn didn't write, one in another file there (newer Ubuntu
# releases ship their own, stricter one), or one already loaded that isn't
# bxn's.
#
# Run in the guest as root:
#   sh -s -- <restriction sysctl> <profile path> <bwrap> <loaded profiles list>
CODEX_BWRAP_SCRIPT='
set -eu
restrict=$1
dest=$2
bwrap=$3
loaded=$4
systemd-detect-virt --vm --quiet || exit 0
[ "$(cat "$restrict" 2>/dev/null)" = 1 ] || exit 0
[ -x "$bwrap" ] || exit 0
mine=no
if [ -e "$dest" ]; then
  if ! grep -q "^# bxn: codex plugin" "$dest"; then
    echo "$dest was not written by bxn; leaving it as it is" >&2
    exit 0
  fi
  mine=yes
fi
for f in "${dest%/*}"/*; do
  [ "$f" != "$dest" ] && [ -f "$f" ] || continue
  if grep -q "^[[:space:]]*profile bwrap[[:space:]]" "$f"; then
    echo "$f has a bwrap profile already; leaving it as it is" >&2
    exit 0
  fi
done
if [ "$mine" = no ] && grep -q "^bwrap (" "$loaded" 2>/dev/null; then
  echo "A bwrap profile is loaded already; leaving it as it is" >&2
  exit 0
fi
profile="# bxn: codex plugin. Lets bubblewrap, which Codex runs commands in, use user namespaces.
abi <abi/4.0>,
include <tunables/global>

profile bwrap $bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}"
printf "%s\n" "$profile" | apparmor_parser -r
printf "%s\n" "$profile" > "$dest"
'

codex_bwrap_profile() {
  printf '%s' "$CODEX_BWRAP_SCRIPT" |
    incus exec "$CONTAINER_NAME" -- sh -s -- \
      /proc/sys/kernel/apparmor_restrict_unprivileged_userns /etc/apparmor.d/bwrap /usr/bin/bwrap \
      /sys/kernel/security/apparmor/profiles ||
    warn "Could not let bubblewrap use user namespaces: Codex's sandbox may fail with 'Failed RTM_NEWADDR'. See SANDBOX.md."
}

# Codex's workspace-write sandbox, its default, cuts the commands it runs off
# from the network, so gh, git and package managers fail with "socket:
# operation not permitted". In a box, the egress allowlist decides which
# hosts are reachable, so bxn lets those commands use the network. A config
# that names sandbox_workspace_write anywhere is left as it is, so a choice
# made there, network off included, stands. The new file is written beside
# the old and moved over it, so a failure leaves the old one.
#
# Run in the guest as the instance user: sh -s
CODEX_NETWORK_SCRIPT='
set -eu
dir="$HOME/.codex"
cfg="$dir/config.toml"
# A config linked from elsewhere, dotfiles say, is edited where it lives.
if [ -L "$cfg" ]; then
  cfg="$(readlink -f "$cfg")"
fi
if [ -f "$cfg" ] && grep -q "sandbox_workspace_write" "$cfg"; then
  exit 0
fi
mkdir -p "$dir"
tmp="$cfg.bxn-new"
# The config can hold tokens (an MCP server'"'"'s env, say): the new file is
# private from the start, then takes the old one'"'"'s mode.
umask 077
rm -f "$tmp"
{
  if [ -s "$cfg" ]; then
    cat "$cfg"
    printf "\n"
  fi
  printf "%s\n" \
    "# bxn: commands Codex runs may use the network. The box'"'"'s egress allowlist" \
    "# decides which hosts they reach." \
    "[sandbox_workspace_write]" \
    "network_access = true"
} > "$tmp"
if [ -f "$cfg" ]; then
  chmod --reference="$cfg" "$tmp"
fi
mv "$tmp" "$cfg"
'

codex_network_access() {
  printf '%s' "$CODEX_NETWORK_SCRIPT" |
    incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'sh -s' ||
    warn "Could not let Codex's commands use the network: set network_access = true under [sandbox_workspace_write] in ~/.codex/config.toml."
}

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/codex" || command -v codex' &>/dev/null
}

plugin_install() {
  log "Installing Codex..."
  # Provision system dependencies as root through the host, so the user never needs sudo.
  incus exec "$CONTAINER_NAME" -- bash -s <<'DEPS'
    set -euo pipefail
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap
DEPS
  codex_bwrap_profile
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -euo pipefail
    npm install --global --prefix "$HOME/.local" @openai/codex
EOF
  codex_network_access
}

plugin_on_launch() {
  codex_bwrap_profile
  codex_network_access
}
