#!/bin/bash
# tests/bxn_skill_test.sh
# The bxn skill's plugin packaging for Claude Code and Codex, and the
# install_shortcuts question that installs it. Stub claude and codex CLIs
# record what they're asked to do; nothing reaches the network.
# Run: bash tests/bxn_skill_test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
refute_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; echo "    actual: $3"; fi
}

command -v jq >/dev/null || { echo "needs jq"; exit 1; }

echo "packaging"
j() { jq -r "$2" "$REPO_ROOT/$1"; }
assert_eq "the Claude Code marketplace is named bxn" "bxn" "$(j .claude-plugin/marketplace.json .name)"
assert_eq "and offers the bxn plugin from agent-plugin" "bxn ./agent-plugin" \
  "$(j .claude-plugin/marketplace.json '.plugins[0] | "\(.name) \(.source)"')"
assert_eq "the Codex marketplace is named bxn" "bxn" "$(j .agents/plugins/marketplace.json .name)"
assert_eq "and offers the same plugin" "bxn ./agent-plugin" \
  "$(j .agents/plugins/marketplace.json '.plugins[0] | "\(.name) \(.source.path)"')"
assert_eq "both plugin manifests are named bxn" "bxn bxn" \
  "$(j agent-plugin/.claude-plugin/plugin.json .name) $(j agent-plugin/.codex-plugin/plugin.json .name)"
assert_eq "and carry the same version" "$(j agent-plugin/.claude-plugin/plugin.json .version)" \
  "$(j agent-plugin/.codex-plugin/plugin.json .version)"
skills_dir="$REPO_ROOT/agent-plugin/$(j agent-plugin/.codex-plugin/plugin.json .skills)"
assert_eq "Codex finds the skill where Claude Code does" "yes" \
  "$([[ -f "$skills_dir/bxn/SKILL.md" && -f "$REPO_ROOT/agent-plugin/skills/bxn/SKILL.md" ]] && echo yes || echo no)"
skill="$REPO_ROOT/agent-plugin/skills/bxn/SKILL.md"
front="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$skill")"
assert_eq "the skill is named bxn" "name: bxn" "$(sed -n 1p <<<"$front")"
assert_contains "its description says when to use it" "description: Use when" "$(sed -n 2p <<<"$front")"
assert_eq "its frontmatter fits the 1024-character limit" "yes" "$( (( ${#front} <= 1024 )) && echo yes || echo no)"

# install_shortcuts, against a throwaway HOME and stub agents. PATH holds only
# the stubs and the system's own tools, so a real claude or codex is never run.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/both" "$fixture/claude-only" "$fixture/none"
cat > "$fixture/both/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "$STUB/calls"
[[ ! -f "$STUB/claude-fails" ]] || exit 1
if [[ "$1 $2" == "plugin install" ]]; then
  mkdir -p "$HOME/.claude/plugins"
  echo '{"plugins":{"bxn@bxn":[]}}' > "$HOME/.claude/plugins/installed_plugins.json"
fi
EOF
cat > "$fixture/both/codex" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "plugin list" ]]; then
  [[ ! -f "$HOME/codex-has-bxn" ]] || printf 'bxn@bxn  installed, enabled  0.1.0  /x\n'
  exit 0
fi
echo "codex $*" >> "$STUB/calls"
[[ ! -f "$STUB/codex-fails" ]] || exit 1
[[ "$1 $2" != "plugin add" ]] || touch "$HOME/codex-has-bxn"
EOF
chmod +x "$fixture/both/claude" "$fixture/both/codex"
cp "$fixture/both/claude" "$fixture/claude-only/claude"

export STUB="$fixture"
run() {
  local bin="$1"
  shift
  rm -f "$STUB/calls"
  HOME="$fixture/home" PATH="$fixture/$bin:/usr/bin:/bin" "$REPO_ROOT/install_shortcuts" --no-chadmux "$@" 2>&1 </dev/null
}
calls() { cat "$STUB/calls" 2>/dev/null || true; }
fresh() { rm -rf "$fixture/home" "$STUB/claude-fails" "$STUB/codex-fails"; mkdir -p "$fixture/home"; }

echo "install_shortcuts without a terminal"
fresh
out="$(run both)"
assert_eq "it installs nothing unasked" "" "$(calls)"
assert_contains "and says how to" "To install the bxn skill for claude codex: ./install_shortcuts --bxn-skill" "$out"
out="$(run both --no-bxn-skill)"
assert_eq "--no-bxn-skill installs nothing" "" "$(calls)"
refute_contains "and says nothing about it" "bxn skill" "$out"

echo "install_shortcuts --bxn-skill"
out="$(run both --bxn-skill)"
assert_eq "it installs the plugin into both agents" \
  "claude plugin install bxn --marketplace MixTapeSoftware/bxn
codex plugin marketplace add MixTapeSoftware/bxn
codex plugin add bxn@bxn" "$(calls)"
assert_contains "and says so" "Installed the bxn skill for: claude codex" "$out"
out="$(run both --bxn-skill)"
assert_eq "a second run installs nothing" "" "$(calls)"
assert_contains "and says it's there" "The bxn skill is already installed" "$out"
out="$(run both)"
refute_contains "nor does it suggest installing it" "To install the bxn skill" "$out"
rm "$fixture/home/codex-has-bxn"
out="$(run both --bxn-skill)"
assert_eq "an agent without it gets it; the other is left alone" \
  "codex plugin marketplace add MixTapeSoftware/bxn
codex plugin add bxn@bxn" "$(calls)"
fresh
touch "$STUB/claude-fails"
rc=0
out="$(run both --bxn-skill)" || rc=$?
assert_eq "one agent failing doesn't fail the install" "0" "$rc"
assert_contains "it says which one" "The bxn skill didn't install for: claude" "$out"
assert_eq "and the other still gets it" "yes" "$([[ -f "$fixture/home/codex-has-bxn" ]] && echo yes || echo no)"
fresh
out="$(run claude-only --bxn-skill)"
assert_eq "with only Claude Code, only it is asked" "claude plugin install bxn --marketplace MixTapeSoftware/bxn" "$(calls)"
out="$(run none --bxn-skill)"
assert_eq "with neither agent, nothing runs" "" "$(calls)"
assert_contains "and it says why" "this host has neither" "$out"
out="$(run none)"
refute_contains "without the flag, it says nothing about it" "bxn skill" "$out"

# The question needs a terminal; util-linux script provides one.
if script --version 2>/dev/null | grep -q util-linux; then
  echo "install_shortcuts in a terminal"
  ask() {
    rm -f "$STUB/calls"
    printf '%s\n' "$1" | HOME="$fixture/home" PATH="$fixture/both:/usr/bin:/bin" \
      script -qec "'$REPO_ROOT/install_shortcuts' --no-chadmux" /dev/null 2>&1
  }
  fresh
  out="$(ask '')"
  assert_contains "it asks, naming the agents" "Install it for claude codex (a plugin from github.com/MixTapeSoftware/bxn)? [y/N]" "$out"
  assert_eq "Enter installs nothing" "" "$(calls)"
  out="$(ask y)"
  assert_contains "y installs it" "codex plugin add bxn@bxn" "$(calls)"
  out="$(ask '')"
  refute_contains "once it's installed, it doesn't ask" "Install it for" "$out"
else
  echo "  skip the question (needs util-linux script)"
fi

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
