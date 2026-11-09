PLUGIN_ID="lazygit"
PLUGIN_NAME="lazygit"
PLUGIN_DESC="Terminal UI for git"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--lazygit"
# No PLUGIN_EGRESS_ALLOW: the download is from github.com, which redirects to
# release-assets.githubusercontent.com, and the egress baseline allows both.

# Pinned release. To re-pin, bump the version and copy both checksums from the
# release's checksums.txt. Asset naming verified 2026-11-09:
#   lazygit_<version>_linux_x86_64.tar.gz / lazygit_<version>_linux_arm64.tar.gz
LAZYGIT_VERSION="0.66.2"
LAZYGIT_SHA256_X86_64="158efc9ddfa1241fab5fb3526bb442c8dc6c4b1904d73213b9e4e93e03c52034"
LAZYGIT_SHA256_ARM64="79a3161eeb642f0473e23db6341f7baabd4a5933e921a9c1167c5d5c765c41a4"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/lazygit"' &>/dev/null
}

plugin_install() {
  log "Installing lazygit $LAZYGIT_VERSION..."
  # Prebuilt release binary into ~/.local/bin as the instance user (no sudo).
  # Host values go in as leading %q-quoted assignments ahead of a quoted
  # heredoc, so none is spliced into the remote script body.
  {
    printf 'LAZYGIT_VERSION=%q\n' "$LAZYGIT_VERSION"
    printf 'LAZYGIT_SHA256_X86_64=%q\n' "$LAZYGIT_SHA256_X86_64"
    printf 'LAZYGIT_SHA256_ARM64=%q\n' "$LAZYGIT_SHA256_ARM64"
    cat <<'EOF'
    set -e
    machine="$(uname -m)"
    case "$machine" in
      x86_64)        ARCH=x86_64; SUM="$LAZYGIT_SHA256_X86_64" ;;
      aarch64|arm64) ARCH=arm64;  SUM="$LAZYGIT_SHA256_ARM64" ;;
      *) echo "lazygit: unsupported architecture: $machine (releases are installed for x86_64 and arm64 only)" >&2; exit 1 ;;
    esac
    # plugin_is_installed only asks whether ~/.local/bin/lazygit is executable,
    # and a build skips a plugin it says is installed. So the binary is checked
    # and run before it's put there, and it arrives by a rename: a failure or
    # a signal at any step leaves either the old binary or none.
    bin="$HOME/.local/bin"
    staged="$bin/.lazygit.new"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "$staged"' EXIT
    asset="lazygit_${LAZYGIT_VERSION}_linux_${ARCH}.tar.gz"
    url="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/${asset}"
    curl -fSL "$url" -o "$tmp/$asset"
    if ! echo "$SUM  $tmp/$asset" | sha256sum -c --status -; then
      echo "lazygit: checksum mismatch for $asset; not installing it" >&2
      exit 1
    fi
    tar -C "$tmp" -xzf "$tmp/$asset" lazygit
    chmod 755 "$tmp/lazygit"
    "$tmp/lazygit" --version
    mkdir -p "$bin"
    install -m755 "$tmp/lazygit" "$staged"
    mv -f "$staged" "$bin/lazygit"
EOF
  } | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -s /bin/bash
}
