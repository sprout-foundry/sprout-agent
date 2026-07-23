#!/bin/bash
# install-deps.sh — minimal bootstrap for the Action runner.
#
# Most Actions runners already have curl, tar, jq installed. We only try to
# install when something is missing AND we have root/sudo. We never block
# the action on this: a missing dependency is a warning, and the actual
# install step that follows will emit a clearer error if a tool is needed
# downstream but absent.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log_info "Checking required tools (curl, tar, jq, gh)..."

need_install=0
for cmd in curl tar jq gh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_warn "$cmd is missing"
        need_install=1
    fi
done

if [ "$need_install" -eq 0 ]; then
    log_ok "All required tools present"
    exit 0
fi

# Best-effort install. We try sudo first (most Actions runners are
# root, in which case sudo is a no-op).
if command -v apt-get >/dev/null 2>&1; then
    log_info "Attempting apt-get install for missing tools..."
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq && apt-get install -y -qq curl tar jq gh || log_warn "apt-get install failed; continuing"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -E apt-get update -qq && sudo -E apt-get install -y -qq curl tar jq gh || log_warn "apt-get install failed; continuing"
    fi
fi

# Final check — if anything is still missing, hard fail with a clear message.
missing=()
for cmd in curl tar jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
    log_err "Missing required tools: ${missing[*]}"
    log_err "Install them manually, or use an Actions runner with these preinstalled."
    exit 1
fi

# gh is strongly recommended (used as a fallback for several features) but
# not required — most features work via curl + API token.
command -v gh >/dev/null 2>&1 || log_warn "'gh' CLI not installed; some convenience paths will fall back to REST API."

log_ok "Tooling ready"
