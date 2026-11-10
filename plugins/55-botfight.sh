PLUGIN_ID="botfight"
PLUGIN_NAME="Botfight"
PLUGIN_DESC="MixTape Software's unattended PR loop, as a plugin for Claude Code and Codex"
PLUGIN_DEFAULT=0
# --mixtape-skills is the flag from before the repository became botfight.
PLUGIN_CLI_FLAGS="--botfight --mixtape-skills"

# Botfight is a Claude Code and a Codex plugin, from the marketplace its
# repository holds (github.com, already on the egress baseline). It installs
# into each of those agents the container has, so this file sorts after
# theirs. Both CLIs' commands are safe to rerun.
#
# The script finds the agents the instance user has. It runs from stdin, so
# every command in it reads /dev/null instead.
_botfight_agents='
  claude="$HOME/.local/bin/claude"; [ -x "$claude" ] || claude=""
  codex="$HOME/.local/bin/codex"; [ -x "$codex" ] || codex="$(command -v codex || true)"
'

# Installed means every agent there has it, and there is at least one.
plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' &>/dev/null <<EOF
    $_botfight_agents
    [ -n "\$claude" ] || [ -n "\$codex" ] || exit 1
    if [ -n "\$claude" ]; then
      grep -qF '"botfight@botfight"' "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/plugins/installed_plugins.json" || exit 1
    fi
    if [ -n "\$codex" ]; then
      "\$codex" plugin list </dev/null 2>/dev/null | grep -Eq '^botfight@botfight[[:space:]]+installed' || exit 1
    fi
EOF
}

plugin_install() {
  log "Installing the botfight plugin for Claude Code and Codex..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<EOF
    set -e
    $_botfight_agents
    if [ -z "\$claude" ] && [ -z "\$codex" ]; then
      echo "[!] botfight is a plugin for Claude Code or Codex, and this container has neither" >&2
      exit 1
    fi
    # No -y: if the marketplace ever declares a command to run for the
    # plugin, the install stops instead of running it unseen.
    if [ -n "\$claude" ]; then
      "\$claude" plugin install botfight --marketplace MixTapeSoftware/botfight </dev/null
    fi
    if [ -n "\$codex" ]; then
      "\$codex" plugin marketplace add MixTapeSoftware/botfight </dev/null
      "\$codex" plugin add botfight@botfight </dev/null
    fi
EOF
}
