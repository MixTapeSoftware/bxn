# Working on Boxen

Boxen provisions Incus containers and VMs for coding agents. The host-side
scripts share container lifecycle, workspace, and plugin setup across agents.

- Keep shell code compatible with Bash 3.2 for macOS; avoid associative arrays.
  Inside `$(...)`, avoid `case` and comments holding quotes or parens: 3.2 seems
  to scan for the closing paren, which is the likely cause of a parse failure
  seen only on macOS. `tests/bash32_test.sh` checks for them.
- Coding agents are optional plugins. Declare `PLUGIN_AGENT_COMMAND` and keep
  shared provisioning independent of a particular agent.
- Install system packages using host-side `incus exec` as root. Install agent
  tools as the instance user without relying on sudo: containers have none
  outside `bxn shell --with-sudo`.
- Never print credentials or interpolate them into remote shell commands.
- Run `bash -n` on changed shell files and the relevant scripts in `tests/`.
- Don't use git worktrees. To work on this codebase in parallel, recommend
  that the developer create a new container (`bxn -c <name>`) or open an
  existing one; each container has its own copy of the code, and git moves
  work between them.
- Review every state machine a change creates or alters before it merges,
  as part of its review. A state machine here is anything that moves
  through states and keeps them: a lifecycle recorded on disk or in
  `incus config` (a build, an egress generation, a plugin source's clone),
  a mode, a lock, or an interactive screen's loop. Write it down (its
  states, the events and their transitions, and what is persisted for
  each state), name the invariants it must keep, and check every state
  against every event, including a failure or a signal at each step, a
  second run of the same command, two runs at once, a reboot, and stdin
  that isn't a terminal. Reproduce each suspected defect with a test, and
  say in the PR which machines were checked and what holds.
- Prefer small, focused PRs. Break a large change into a stack of dependent
  PRs; the `stacked-prs` skill describes how.
- Shared skills live in `.agents/skills/`; `.claude/skills` and
  `.grok/skills` link there for each agent's native discovery.
