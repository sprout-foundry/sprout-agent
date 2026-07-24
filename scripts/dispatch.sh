#!/bin/bash
# dispatch.sh — entry point for the composite Action's main step.
#
# Decides which mode-specific script to invoke based on $MODE, then routes
# to it. Also does the common preamble: pull the GitHub event payload,
# stash the trigger phrase comment (if any), and verify the prerequisites
# (sprout installed, token set) before kicking off the real work.
set -euo pipefail
source "$(dirname "$0")/common.sh"

MODE="${MODE:-review}"

log_info "Sprout Agent dispatching — mode=$MODE"
log_debug "run dir: $SPROUT_RUN_DIR"
log_debug "trigger phrase: $EFFECTIVE_TRIGGER_PHRASE"
log_debug "max iterations: $EFFECTIVE_MAX_ITERATIONS, budget: $EFFECTIVE_MAX_BUDGET_USD, timeout: ${EFFECTIVE_TIMEOUT_MINUTES}m"

# Validate required inputs up front. Better to fail fast on a typo than to
# debug the deeper "sprout agent failed with exit code 2" mystery.
[ -n "${GITHUB_TOKEN:-}" ]  || { log_err "github-token is required"; exit 1; }
[ -n "${AI_PROVIDER:-}" ]   || { log_err "primary-provider is required"; exit 1; }
[ -n "${AI_MODEL:-}" ]      || { log_err "primary-model is required"; exit 1; }

# Comment-trigger filtering. Other events (PR open, push, workflow_dispatch)
# run unconditionally. We only skip when this is an issue_comment that
# doesn't include the configured trigger phrase.
COMMENT_BODY=$(event_comment_body)
if [ "$GITHUB_EVENT_NAME" = "issue_comment" ] && [ -n "$COMMENT_BODY" ]; then
    if printf '%s' "$COMMENT_BODY" | grep -qF "$EFFECTIVE_TRIGGER_PHRASE"; then
        log_info "Comment contains trigger phrase '$EFFECTIVE_TRIGGER_PHRASE' — proceeding"
    else
        log_info "Comment does not contain '$EFFECTIVE_TRIGGER_PHRASE' — skipping"
        emit_output "success=false"
        exit 0
    fi
fi

# Configure MCP only when needed. Review mode rarely needs it; fix mode's
# orchestrator benefits from a github MCP server for posting status
# comments and looking up linked PRs.
case "$EFFECTIVE_MCP" in
    github|on|true)
        log_info "Enabling GitHub MCP server (mode=$MODE)"
        "$SPROUT_AGENT_SCRIPTS/configure-mcp.sh"
        ;;
    *)
        log_debug "MCP disabled (mode=$MODE, mcp=$EFFECTIVE_MCP)"
        ;;
esac

# Run the mode-specific entry point. Each script returns 0 on success and
# writes its outputs to $GITHUB_OUTPUT via emit_output().
case "$MODE" in
    review) "$SPROUT_AGENT_MODES/review.sh" ;;
    fix)    "$SPROUT_AGENT_MODES/fix.sh"    ;;
    plan)   "$SPROUT_AGENT_MODES/plan.sh"   ;;
    *)
        log_err "Unknown mode: $MODE (expected: review, fix, plan)"
        exit 1
        ;;
esac
