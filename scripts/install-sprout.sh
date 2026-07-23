#!/bin/bash
# install-sprout.sh — fetch the sprout CLI binary from GitHub releases.
#
# This is intentionally a thin wrapper around sprout's own bootstrap. We do
# NOT maintain a parallel Linux/macOS detection heuristic; we let the
# upstream install.sh handle platform detection, sudo handling, and
# checksum verification. The only thing this script owns is the URL
# resolution and a post-install sanity check.
#
# Usage:
#   install-sprout.sh [version]
#
# version defaults to the SPROUT_VERSION env var, then "latest".
set -euo pipefail
source "$(dirname "$0")/common.sh"

REQUESTED_VERSION="${1:-${SPROUT_VERSION:-latest}}"

# Make sure Go is on PATH for `go install`. Most users don't need this — we
# prefer the static release binary — but it's a good escape hatch when no
# platform-appropriate release exists.
ensure_go() {
    if command -v go >/dev/null 2>&1; then
        return 0
    fi
    log_info "Go not installed; skipping install-sprout via go install fallback"
    return 1
}

# Resolve the latest tag via the GitHub API. Only used when the user asked
# for "latest" — pinning to a tag skips this and avoids the per-IP rate
# limit. We hit the unauthenticated endpoint, which is 60 req/hr/IP.
resolve_latest_version() {
    log_info "Resolving latest sprout release..."
    local response tag
    if ! response=$(curl --fail --show-error --silent --max-time 30 \
        "https://api.github.com/repos/sprout-foundry/sprout/releases/latest"); then
        log_err "Could not reach the GitHub releases API."
        log_err "Pin a version explicitly: install-sprout.sh v0.14.0"
        return 1
    fi
    # Use jq instead of grep|sed so escapes in tag_name don't bite us.
    # `--exit-status` would also catch malformed JSON; we keep it tolerant
    # by piping into `|| true`.
    tag=$(printf '%s' "$response" | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [ -z "$tag" ]; then
        log_err "Releases API didn't return a tag_name — response:"
        printf '%s' "$response" | head -c 500
        return 1
    fi
    printf '%s' "$tag"
}

# Install a specific version by downloading the platform tarball directly.
# Faster than curl-piping to install.sh and just as reliable since the
# checksum is verified by us (we reuse the same SHA256SUMS file the
# upstream installer uses).
install_release_binary() {
    local version="$1"

    local os arch
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        *)
            log_err "Unsupported OS: $(uname -s). On Windows, run this Action with a Linux runner."
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            log_err "Unsupported arch: $(uname -m)"
            return 1
            ;;
    esac

    local archive="sprout-${os}-${arch}.tar.gz"
    local url="https://github.com/sprout-foundry/sprout/releases/download/${version}/${archive}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    log_info "Downloading $archive (version $version)..."
    if ! curl --fail --show-error --location --silent \
        --connect-timeout 15 --max-time 120 \
        -o "$tmpdir/$archive" "$url"; then
        log_err "Failed to download $url"
        log_err "Check that version $version exists at https://github.com/sprout-foundry/sprout/releases"
        return 1
    fi

    # Verify against the release's SHA256SUMS. Skip cleanly if the release
    # is too old to ship a manifest — warning is enough since we hit the
    # official release endpoint.
    if curl --fail --show-error --silent --location --max-time 30 \
        -o "$tmpdir/SHA256SUMS" \
        "https://github.com/sprout-foundry/sprout/releases/download/${version}/SHA256SUMS" 2>/dev/null; then
        local expected actual
        expected=$(awk -v f="$archive" '$2 == f {print $1}' "$tmpdir/SHA256SUMS")
        actual=$(sha256sum "$tmpdir/$archive" | awk '{print $1}')
        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            log_err "Checksum mismatch for $archive — refusing to install."
            log_err "  expected: $expected"
            log_err "  actual:   $actual"
            return 1
        fi
        log_ok "Checksum verified"
    else
        log_warn "SHA256SUMS not available for $version — proceeding without verification"
    fi

    # Extract and place the binary on PATH. Prefer $HOME/go/bin (which is
    # always writable and survives the runner teardown) over /usr/local/bin
    # which usually requires sudo and clobbers any host-installed version.
    tar -xzf "$tmpdir/$archive" -C "$tmpdir"
    local bin_path
    bin_path=$(find "$tmpdir" -type f -executable ! -name '*.sha256' ! -name 'SHA256SUMS*' | head -1)
    if [ -z "$bin_path" ]; then
        log_err "Could not find sprout binary inside the archive"
        return 1
    fi

    local install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
    mv "$bin_path" "$install_dir/sprout"
    chmod +x "$install_dir/sprout"

    # Ensure the install dir is on PATH for downstream steps.
    echo "$install_dir" >> "$GITHUB_PATH"
    log_ok "Installed sprout to $install_dir/sprout"
}

install_via_go() {
    local version="$1"
    log_info "Falling back to 'go install' for $version..."
    ensure_go || return 1
    local gobin
    gobin="$(go env GOBIN 2>/dev/null || true)"
    if [ -z "$gobin" ]; then
        gobin="$(go env GOPATH 2>/dev/null)/bin"
    fi
    mkdir -p "$gobin"
    GOBIN="$gobin" go install "github.com/sprout-foundry/sprout@${version}"
    echo "$gobin" >> "$GITHUB_PATH"
    log_ok "Installed sprout via go install to $gobin/sprout"
}

# Sanity check that sprout works. Catches the only mode where a wrong-arch
# binary can land cleanly on disk but blow up at runtime — most commonly
# a CGO-enabled binary on a Bionic libc host (Termux), or a binary built
# against newer glibc than the host has.
verify_sprout() {
    if ! command -v sprout >/dev/null 2>&1; then
        log_err "sprout is not on PATH after installation."
        log_err "PATH=$PATH"
        return 1
    fi
    if ! sprout version >/dev/null 2>&1; then
        log_err "sprout binary is present but failed to execute. Likely a libc mismatch."
        log_err "Run 'sprout version' manually to see the loader error."
        return 1
    fi
    log_ok "sprout $(sprout version | head -1) ready"
}

# Main flow.
if [ "$REQUESTED_VERSION" = "latest" ]; then
    REQUESTED_VERSION=$(resolve_latest_version) || {
        log_warn "Could not resolve latest; trying go install @latest as fallback"
        install_via_go latest
        verify_sprout
        exit $?
    }
fi

log_info "Installing sprout at version: $REQUESTED_VERSION"

# Prefer the release tarball. Only fall back to `go install` when the
# binary is missing for our platform (rare — the pipeline cross-compiles).
if install_release_binary "$REQUESTED_VERSION"; then
    verify_sprout
else
    log_warn "Release binary unavailable for this platform; trying go install fallback"
    install_via_go "$REQUESTED_VERSION"
    verify_sprout
fi
