PLUGIN_ID="fly"
PLUGIN_NAME="Fly CLI"
PLUGIN_DESC="flyctl, the command line for Fly.io (fly)"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--fly --flyctl"
# What flyctl reaches for apps, Machines and deploys:
#   api.fly.io       the GraphQL API, the login's polling and update checks;
#   api.machines.dev the Machines API;
#   registry.fly.io  the image registry deploys push to;
#   api.depot.dev    the Depot builders `fly deploy` uses by default.
# upload: each takes data from any Fly account, the one the box is logged in
# to or another. The release download comes from github.com, which the
# baseline allows. Not listed: the build machine Depot assigns and the
# WireGuard gateways `fly ssh console` and `fly proxy` go through, which the
# API names only when it's asked; `bxn egress log` shows them. Nor is
# flyctl-metrics.fly.dev, its usage reporting, which it sends in the
# background and does without.
PLUGIN_EGRESS_ALLOW="api.fly.io api.machines.dev registry.fly.io api.depot.dev"
# Prints a URL to open in a browser, then waits for the login there.
PLUGIN_LOGIN_COMMAND="fly auth login"

# Pinned release. To re-pin, bump the version and copy both checksums from the
# release's flyctl_<version>_checksums.txt. Asset naming verified 2026-11-11:
#   flyctl_<version>_Linux_x86_64.tar.gz / flyctl_<version>_Linux_arm64.tar.gz
# flyctl updates itself only when it lives under ~/.fly, so this one stays at
# the pinned version; it says when a newer one is out.
FLY_VERSION="0.5.7"
FLY_SHA256_X86_64="1b340c3f326abc34659b7bc1f2eed69eac31115c9796e325596e27687ea421a5"
FLY_SHA256_ARM64="01cb77e62cc00b61f20c31a070c462b61733dd7d6a2c5aee7e5287d41b4ec1c8"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'test -x "$HOME/.local/bin/flyctl" && test -L "$HOME/.local/bin/fly"' &>/dev/null
}

plugin_install() {
  log "Installing flyctl $FLY_VERSION..."
  # Prebuilt release binary into ~/.local/bin as the instance user (no sudo).
  # Host values go in as leading %q-quoted assignments ahead of a quoted
  # heredoc, so none is spliced into the remote script body.
  {
    printf 'FLY_VERSION=%q\n' "$FLY_VERSION"
    printf 'FLY_SHA256_X86_64=%q\n' "$FLY_SHA256_X86_64"
    printf 'FLY_SHA256_ARM64=%q\n' "$FLY_SHA256_ARM64"
    cat <<'EOF'
    set -e
    machine="$(uname -m)"
    case "$machine" in
      x86_64)        ARCH=x86_64; SUM="$FLY_SHA256_X86_64" ;;
      aarch64|arm64) ARCH=arm64;  SUM="$FLY_SHA256_ARM64" ;;
      *) echo "flyctl: unsupported architecture: $machine (releases are installed for x86_64 and arm64 only)" >&2; exit 1 ;;
    esac
    # plugin_is_installed asks for ~/.local/bin/flyctl and the fly link, and a
    # build skips a plugin it says is installed. So the binary is checked and
    # run before it's put there, it arrives by a rename, and the link comes
    # last: a failure or a signal at any step leaves the old install or one
    # that a rebuild finishes.
    bin="$HOME/.local/bin"
    staged="$bin/.flyctl.new"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "$staged"' EXIT
    asset="flyctl_${FLY_VERSION}_Linux_${ARCH}.tar.gz"
    url="https://github.com/superfly/flyctl/releases/download/v${FLY_VERSION}/${asset}"
    curl -fSL "$url" -o "$tmp/$asset"
    if ! echo "$SUM  $tmp/$asset" | sha256sum -c --status -; then
      echo "flyctl: checksum mismatch for $asset; not installing it" >&2
      exit 1
    fi
    tar -C "$tmp" -xzf "$tmp/$asset" flyctl
    chmod 755 "$tmp/flyctl"
    FLY_NO_UPDATE_CHECK=1 "$tmp/flyctl" version
    mkdir -p "$bin"
    install -m755 "$tmp/flyctl" "$staged"
    mv -f "$staged" "$bin/flyctl"
    ln -sfn flyctl "$bin/fly"
EOF
  } | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -s /bin/bash
}
