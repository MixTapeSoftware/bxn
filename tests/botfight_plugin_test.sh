#!/bin/bash
# tests/botfight_plugin_test.sh
# The botfight plugin is opt-in and installs botfight as a plugin, from its
# repository's marketplace, into each of Claude Code and Codex the container
# has, as the instance user: not a skill link, and not just a setting that
# enables it. It's installed only when every agent there has it, and it fails
# when there is no agent to install into. Runs the plugin's scripts with
# stand-in claude and codex.
# Run: bash tests/botfight_plugin_test.sh

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
H="$SANDBOX/home"
mkdir -p "$SANDBOX/agents"
# claude: records its arguments; `plugin install` with --marketplace adds the
# plugin to the record Claude keeps, or fails when told to.
cat > "$SANDBOX/agents/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/claude.log"
if [[ "$1 $2" == "plugin install" ]]; then
  [[ -f "$HOME/.fail" ]] && { echo "network error" >&2; exit 1; }
  mkdir -p "$HOME/.claude/plugins"
  printf '{"version":2,"plugins":{"%s@botfight":[{"scope":"user"}]}}\n' "$3" > "$HOME/.claude/plugins/installed_plugins.json"
fi
EOF
# codex: records its arguments; `plugin add` installs from an added
# marketplace, and `plugin list` reports what's installed as Codex does.
cat > "$SANDBOX/agents/codex" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "plugin list" ]] || echo "$*" >> "$HOME/codex.log"
case "$1 $2 $3" in
  "plugin marketplace add") touch "$HOME/.codex-marketplace" ;;
  "plugin add botfight@botfight")
    [[ -f "$HOME/.codex-marketplace" ]] || { echo "no marketplace" >&2; exit 1; }
    touch "$HOME/.codex-installed" ;;
  "plugin list "*)
    echo "PLUGIN             STATUS              VERSION"
    if [[ -f "$HOME/.codex-installed" ]]; then echo "botfight@botfight  installed, enabled  0.2.1"
    elif [[ -f "$HOME/.codex-marketplace" ]]; then echo "botfight@botfight  available          0.2.1"; fi ;;
esac
EOF
chmod +x "$SANDBOX/agents/claude" "$SANDBOX/agents/codex"

log() { :; }
# The plugin's scripts, run as the instance user would run them.
incus() {
  [[ "$1 $2 $3 $4 $5 $6 $7 $8" == "exec box -- su - dev -c bash -s" ]] || return 1
  env -i HOME="$H" PATH="/usr/bin:/bin" bash -s
}
installed() { plugin_is_installed && echo yes || echo no; }
# A home with the named agents in ~/.local/bin.
home_with() {
  rm -rf "$H"; mkdir -p "$H/.local/bin"
  local a; for a in "$@"; do cp "$SANDBOX/agents/$a" "$H/.local/bin/$a"; done
}
CONTAINER_NAME=box HOST_USER=dev
# shellcheck source=../plugins/55-botfight.sh
source "$REPO_ROOT/plugins/55-botfight.sh"

echo "the plugin"
assert_eq "it's opt-in" "0" "$PLUGIN_DEFAULT"
assert_eq "--botfight asks for it, as the old flag still does" "--botfight --mixtape-skills" "$PLUGIN_CLI_FLAGS"
assert_eq "it needs no hosts beyond the baseline" "" "${PLUGIN_EGRESS_ALLOW:-}"
assert_eq "its description has no colon" "no" "$([[ "$PLUGIN_DESC" == *:* ]] && echo yes || echo no)"
# Plugins install in PLUGIN_NAME order, sorted as boxen.create sorts them.
assert_eq "it installs after the agents it installs into" \
  "Claude Code|Codex|MixTape Botfight" \
  "$(for f in "$REPO_ROOT"/plugins/*.sh; do (PLUGIN_NAME=""; source "$f" >/dev/null 2>&1; printf '%s\n' "$PLUGIN_NAME"); done |
     sort -f -s | grep -E '^(Claude Code|Codex|MixTape Botfight)$' | paste -sd'|' -)"

echo "Claude Code and Codex both"
home_with claude codex
assert_eq "it isn't installed yet" "no" "$(installed)"
plugin_install
assert_eq "Claude's CLI installs it from its marketplace, without -y" \
  "plugin install botfight --marketplace MixTapeSoftware/botfight" "$(cat "$H/claude.log")"
assert_eq "Codex adds the marketplace, then installs the plugin from it" \
  "plugin marketplace add MixTapeSoftware/botfight|plugin add botfight@botfight" "$(paste -sd'|' "$H/codex.log")"
assert_eq "then it's installed" "yes" "$(installed)"
plugin_install
assert_eq "a rerun runs the same commands again" "2" "$(wc -l < "$H/claude.log" | tr -d ' ')"
assert_eq "and it stays installed" "yes" "$(installed)"

echo "one agent"
home_with claude
plugin_install
assert_eq "with only Claude Code, it installs there" "yes" "$(installed)"
assert_eq "and calls no codex" "no" "$([[ -e "$H/codex.log" ]] && echo yes || echo no)"
home_with codex
plugin_install
assert_eq "with only Codex, it installs there" "yes" "$(installed)"
assert_eq "and calls no claude" "no" "$([[ -e "$H/claude.log" ]] && echo yes || echo no)"

echo "partly installed"
home_with claude codex
touch "$H/.codex-marketplace"
assert_eq "a marketplace that's only added isn't an install" "no" "$(installed)"
"$H/.local/bin/claude" plugin install botfight --marketplace MixTapeSoftware/botfight
assert_eq "nor is having it in only one of the agents" "no" "$(installed)"

echo "failure"
home_with claude codex
touch "$H/.fail"
( set -e; plugin_install ) 2>/dev/null && rc=0 || rc=$?
assert_eq "a failed install fails the plugin (the build warns and goes on)" "1" "$rc"
assert_eq "and it isn't reported installed" "no" "$(installed)"
home_with
out="$( ( set -e; plugin_install ) 2>&1 )" && rc=0 || rc=$?
assert_eq "with no agent to install into, it fails" "1" "$rc"
assert_contains "and says why" "has neither" "$out"
assert_eq "and it isn't installed" "no" "$(installed)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
