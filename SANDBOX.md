# The Sandbox

How far a bxn container keeps a coding agent away from your machine, what it doesn't stop, and what to do about each gap. The network has its own page: [NETWORKING.md](NETWORKING.md). No sandbox closes every gap. This page lists the ones we know of, so you can choose what to put in a container and how much to watch it.

## What it does

- **An unprivileged container.** Root inside the container is an ordinary user on the host, and each container gets its own range of user IDs (`security.idmap.isolated`), so two containers' users are never the same host user. Nesting is off, and memory and CPU are limited (6GB and 4 CPUs by default).
- **Nothing from the host is mounted.** The workspace is a copy, `.git` included. Work leaves through git (see [Getting work out](README.md#getting-work-out)).
- **No sudo** in a container by default.
- **Network isolation.** A container can't reach other instances, services on the host, or private and LAN addresses. By default, new containers are built on the [egress allowlist](README.md#egress-allowlist) under `enforce`. The allowlist is enforced outside the container, so root inside it can't turn it off. You can: `--egress report` logs instead of blocking, `--egress off` builds without it, and `--insecure-network` turns the isolation off too.
- **A VM on request.** `--vm` gives the instance its own kernel.

## What remains

### The kernel

A container shares the host's kernel. A kernel bug that a container can reach may be a way out to the host. A VM (`--vm`) runs its own kernel, so a way out of the guest kernel still has to cross the hypervisor. Use a VM for code you don't trust, and for any work you won't be watching.

The Docker plugin relaxes a container's sandbox: it turns on nesting and syscall interception, so Docker can manage its own containers on the shared kernel. In a VM, Docker relaxes nothing. Use `--docker` with `--vm`.

Codex runs each command it's given inside bubblewrap, its own sandbox, which needs user namespaces. A VM runs Ubuntu's kernel, and Ubuntu stops unprivileged programs from using user namespaces unless an AppArmor profile allows it. Without one, every command Codex runs fails with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`. So in a VM, the Codex plugin loads a profile that allows `/usr/bin/bwrap`, and nothing else. A guest that already has a bwrap profile, as newer Ubuntu releases do, keeps its own. The cost: anything in the VM can run bwrap and reach the parts of the kernel that user namespaces open up, but that kernel is the guest's, behind the hypervisor. A container shares the host's kernel and is left alone. A VM built before bxn did this doesn't have the profile. Rebuild it; a new VM from an older template gets the profile when it launches.

On macOS, every instance runs inside Colima's Linux VM, so the shared kernel is that VM's, not macOS's. Colima's default is to mount your home directory into that VM, writable, so a way out of a container would land next to it. bxn starts its Colima profile with no folders from the Mac mounted (`--mount none`, which needs Colima 0.10.0 or later; with an older one bxn says to upgrade), and it doesn't use any. A profile made by an earlier bxn loses its mount the next time bxn starts it. While such a profile is running, `bxn -c` warns and says how to remove the mount: `colima stop -p boxen && colima start -p boxen --mount none`.

### Root inside the container

No sudo doesn't mean no way to root:

- **The `docker` group** (`--docker`) is as good as root inside the container.
- **Shell startup files.** Anything running as your user can edit `~/.zshrc` and the like. A later `bxn shell --with-sudo` session runs them, with sudo. Treat `--with-sudo` as handing root to whatever has run in the container.
- **A build that didn't finish** may still have the sudo it uses while building. `bxn shell` warns about it, and `bxn doctor` lists it. Delete it with `bxn rm`.

Root inside the container is still not root on the host. The container's network rules, whatever its egress mode, live outside it, so root can't change them. A build that didn't finish may not have its allowlist locked yet; `bxn doctor` lists one. But root can change anything else inside the container.

### Credentials in the container

What you give a container, anything in it can read and use:

- tokens given to plugins (the GitHub token, the 1Password service account token);
- values set with `bxn env`;
- the agent's own login.

They live in the container's Incus environment, in `~/.zshenv`, or in the agent's config. The allowlist doesn't help here. A GitHub token can push to any repository it can write to, and github.com is on the list.

- Give an agent container as few credentials as possible. The README's [daily flow](README.md#the-development-workflow) keeps them in a separate dev container that you drive yourself.
- Use fine-grained tokens, limited to the repositories the work needs, and short-lived where the service allows.
- A template keeps logins made while it was built. Only the `GH_TOKEN` and `OP_SERVICE_ACCOUNT_TOKEN` exports and Tailscale's state are removed (see [Templates](README.md#templates)).

### Work coming back to the host

`git fetch` brings commits, never the container's git config or hooks. But a commit can change anything in the tree that your host runs: `package.json` scripts, `Makefile`s, `.envrc`, `.vscode/tasks.json`, hook managers like husky. Read the diff before you run anything from it.

### Your terminal

`bxn shell` and `bxn <container>` connect your terminal to programs in the container. A program can print escape sequences your terminal acts on: setting the window title, and on some terminals writing to the clipboard (OSC 52). Keep your terminal and tmux up to date. If you don't need programs to write to your clipboard, turn that off.

### The network

[NETWORKING.md](NETWORKING.md#what-remains) has the details. In short:

- The allowlist decides where connections go, not what they carry. Data sent to an allowed host that takes uploads from any account, such as a code host, a registry or a paste site, can reach someone else's account.
- Some shared front ends route on a name inside the encrypted request, which the proxy can't see.
- A container with Tailscale can reach whatever its tag may reach on your tailnet, and isn't confined against a determined agent (see [Tailscale](README.md#tailscale)).
- `bxn -n -b <address>` serves a container's port on that address, to anyone who can reach it.
- `--insecure-network` turns the isolation off.
- One egress container serves every container behind it. Use separate ones (`--egress-container`) for work that must not mix, such as different clients'.

### Resources

Memory and CPU are limited. A container's number of processes, its root disk size, and its network bandwidth are not. A runaway or hostile process can fork until the host struggles, fill the storage pool that every instance shares, or use your whole uplink. A VM's root disk is sized (20GiB by default).

## What bxn trusts

- **Your host and Incus.** Membership of the `incus-admin` group is as good as root on the host.
- **Plugins.** A plugin runs on your host as you, with root in the container. A [plugin source](README.md#plugins-from-a-repository) is as trusted as this repository: pin a commit when that matters.
- **The base image**, `images:ubuntu/24.04` from the Incus image server, unless you choose another.

The agent and the tools it installs are what the sandbox contains. bxn doesn't trust them.

## Choosing a setup

| Work | Setup |
|---|---|
| Code you don't trust, or a task you won't watch | `--vm`, the allowlist on `enforce`, no credentials |
| Docker | `--vm --docker` |
| Pushing, publishing, secrets | A separate container you drive yourself, with fine-grained tokens |
| Different clients' work | A container each, behind separate egress containers |
