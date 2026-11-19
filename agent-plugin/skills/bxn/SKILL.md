---
name: bxn
description: Use when working with Boxen (the bxn CLI) on the host - creating, opening, stopping or deleting boxes (Incus containers and VMs for coding agents), setting a box's environment variables, changing which hosts a box may reach, exposing a box's port, or working out why a box can't reach a host, port or service, or can't be reached.
---

# bxn

bxn runs on the host and manages boxes: Incus VMs or system containers, each with a copy of a workspace and a coding agent, named `HANDLE-AGENT-PROJECT`. There is no bxn inside a box. For syntax, read `bxn -h`, `bxn egress -h` and `bxn create -h` first; this skill covers what the help doesn't.

## Steps that belong to the user

- **Anything that prompts:** `bxn -c` (pickers, token prompts), `bxn -e <box> <VAR>` (pastes a secret silently), and `bxn rm` when it finds unpushed work. Give the user the exact command. In Claude Code they can run it with `! <command>`.
- **Secrets:** never put one in a command line, an echo or a pipe, and never repeat it back. If a secret was pasted into the chat, suggest rotating it.
- **Widening access or deleting:** ask first, naming the box and the host. That covers `egress allow --all`, `egress mode report|off`, `egress baseline <box> on`, `egress upload-cap <box> off`, `--insecure-network`, `bxn rm --force` and `bxn -ka`. Allow a host for one box (`bxn egress allow <box> <host>`) rather than every box.

## What can reach what

| Path | Decided by | Ports |
|---|---|---|
| Inside the box (localhost) | nothing | any |
| Box → public internet | the box's egress allowlist, by hostname | 80 and 443 under `enforce` and `report`; any port with `mode off` |
| Box → private or LAN address, the host, another box | network isolation | blocked in every egress mode; only a box built with `--insecure-network` gets through |
| Box → a device on the user's tailnet (box has the Tailscale plugin) | the tailnet policy for the box's tag | whatever the policy grants |
| Tailnet → box, through `bxn serve <box> <port>` | the tailnet policy | whatever the policy allows to the box's tag |
| Host → box, through `bxn -n <box> <port>` | nothing | any; on the host's localhost unless `-b` or `-H` is given |

What follows from it:

- `bxn egress allow` takes hostnames for 80 and 443. There is no `host:port` entry. For another port on a public host, the choices are `bxn egress mode <box> off` (ask first) or reaching the service over the tailnet.
- A name that resolves to a private address (a corporate database, a LAN machine, a service on the host) stays blocked even with `mode off`. Route it over the tailnet with a narrow grant (one device, named ports), or rebuild the box with `--insecure-network` if the user accepts that.
- If `bxn serve` succeeds but the page spins on the user's device, the tailnet policy doesn't allow that port to the box's tag. The user adds `tcp:<port>` to the rule for that tag.
- Before allowing anything, confirm the block with `bxn egress log <box>`, which lists blocked hosts first.
- **The request fails, but the log shows no block for that host:** the tool isn't using the proxy, so the allowlist never saw the request, and allowing the host changes nothing. Under the allowlist a box has no DNS of its own, so such a tool fails with a DNS error (`EAI_AGAIN`, `ENOTFOUND`, "Temporary failure in name resolution"), or its connection is refused at once. Fix the tool's proxy setting.
  - bxn sets `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and npm's proxy settings in the box, and gives Docker's client the proxy.
  - Common tools that ignore those: the JVM, which needs `-Dhttps.proxyHost` and `-Dhttps.proxyPort`; containers a tool starts through Docker's API itself, such as the Supabase CLI's, which need the variables passed in through that tool's own config; Node's `fetch` before Node 22.21; and programs with their own HTTP client settings.

## More

The docs are in the bxn checkout (`ls -l "$(command -v bxn)"` shows where it is): README.md (Egress Allowlist, Tailscale, Expose Container Ports), NETWORKING.md and SANDBOX.md.
