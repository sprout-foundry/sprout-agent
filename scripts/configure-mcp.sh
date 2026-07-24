#!/bin/bash
# configure-mcp.sh — install a minimal MCP config that gives the agent
# access to a GitHub MCP server. Useful in fix mode where the orchestrator
# needs to look up linked PRs and post status comments.
#
# We do NOT enable MCP in review mode by default; the GitHub MCP tool set
# is overkill for inline review comments and adds latency. Callers can
# opt in via `with: mcp: github`.
set -euo pipefail
source "$(dirname "$0")/common.sh"

mkdir -p "$SPROUT_CONFIG/mcp"

cat > "$SPROUT_CONFIG/mcp_config.json" <<EOF
{
  "enabled": true,
  "servers": {
    "github": {
      "name": "github",
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/",
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN:-}"
      },
      "timeout": 60000000000,
      "auto_start": true,
      "max_restarts": 3
    }
  },
  "auto_start": true,
  "auto_discover": true,
  "timeout": 60000000000
}
EOF

log_ok "MCP configured (github server)"
