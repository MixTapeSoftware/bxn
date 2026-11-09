PLUGIN_ID="codex"
PLUGIN_NAME="Codex"
PLUGIN_DESC="OpenAI coding agent"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--codex"
PLUGIN_AGENT_COMMAND="codex"
# A template made before the bubblewrap profile below gets it on launch.
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
# leaves nothing behind, and a success outlives a reboot. A profile at that
# path that bxn didn't write is left as it is.
#
# Run in the guest as root: sh -s -- <restriction sysctl> <profile path> <bwrap>
CODEX_BWRAP_SCRIPT='
set -eu
restrict=$1
dest=$2
bwrap=$3
systemd-detect-virt --vm --quiet || exit 0
[ "$(cat "$restrict" 2>/dev/null)" = 1 ] || exit 0
[ -x "$bwrap" ] || exit 0
if [ -e "$dest" ] && ! grep -q "^# bxn: codex plugin" "$dest"; then
  echo "$dest was not written by bxn; leaving it as it is" >&2
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
      /proc/sys/kernel/apparmor_restrict_unprivileged_userns /etc/apparmor.d/bwrap /usr/bin/bwrap ||
    warn "Could not let bubblewrap use user namespaces: Codex's sandbox may fail with 'Failed RTM_NEWADDR'. See SANDBOX.md."
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
}

plugin_on_launch() {
  codex_bwrap_profile
}
