#!/bin/bash
# review.sh — PR review mode.
#
# Builds a workflow JSON that wires the reviewer persona into sprout's
# workflow engine, points it at the PR context, and runs a single-pass
# review with budget enforcement. Posts review results as GitHub
# status checks + inline comments.
#
# Functions are intentionally defined after their use sites; shellcheck
# doesn't see the run-time order, so silence the cosmetic warning.
# shellcheck disable=SC2218
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"
source "$SPROUT_AGENT_MODES/review_lib.sh"

review_main() {
log_info "Review mode — bootstrapping workflow JSON"

PR_NUMBER=$(event_pr_number)
if [ -z "$PR_NUMBER" ]; then
    log_err "Could not determine PR number from event payload"
    log_err "Event: ${GITHUB_EVENT_NAME:-<unset>}"
    emit_output "success=false"
    exit 1
fi
log_info "Reviewing PR #$PR_NUMBER in $GITHUB_REPOSITORY"

# Fail fast on missing PR number context. action.yml marks this input
# required, but a malformed value would still reach here — guard against
# malformed API URLs.
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    log_err "PR number '$PR_NUMBER' is not a positive integer"
    emit_output "success=false"
    exit 1
fi

# Stash PR context to disk so the workflow can reference it without a
# second API roundtrip. Doing this here (once) instead of inside the
# model means the reviewer spends its context budget on the code, not
# on parsing the GitHub event JSON.
SPROUT_RUN_DIR="$SPROUT_RUN_DIR" \
GITHUB_TOKEN="$GITHUB_TOKEN" \
GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
PR_NUMBER="$PR_NUMBER" \
    review_fetch_context

REVIEW_JSON="$SPROUT_RUN_DIR/review.json"
SUMMARY_MD="$SPROUT_RUN_DIR/summary.md"

# Render the workflow JSON with the user's primary/subagent overrides and
# the resolved budget. We render to disk so the user can debug it via the
# action's "Run" logs.
WORKFLOW_JSON="$SPROUT_RUN_DIR/workflow.json"
review_render_workflow_json "$WORKFLOW_JSON"

# (Optional) pre-flight check: fetch the PR with the workspace checked out
# correctly. If the user forgot `ref: ${{ github.event.pull_request.head.ref }}`
# in their checkout step, files in the diff will be missing on disk. We
# surface this loudly so the reviewer doesn't waste tokens thinking the
# PR is empty.
if check_missing_diff_files "$SPROUT_RUN_DIR/full.diff"; then
    log_warn "Some files added in this PR are missing from the checkout."
    log_warn "Update your checkout step to: ref: \${{ github.event.pull_request.head.ref }}"
fi

log_info "Invoking sprout agent..."
log_info "Command: timeout ${EFFECTIVE_TIMEOUT_MINUTES}m sprout agent \\"
log_info "         --workflow-config $WORKFLOW_JSON --no-web-ui --no-stream \\"
log_info "         --prompt-stdin < $SPROUT_RUN_DIR/prompt.md"

# Fail fast if the prompt didn't get written — context fetch probably
# bailed. Without this, the user sees an opaque "sprout exit 1".
if [ ! -s "$SPROUT_RUN_DIR/prompt.md" ]; then
    log_err "Prompt file is missing or empty — context fetch probably failed"
    log_err "See $SPROUT_RUN_DIR for partial outputs"
    emit_output "success=false"
    exit 1
fi

# Pass the user prompt via stdin so we never hit the OS ARG_MAX limit.
# sprout's --prompt-stdin flag reads the full body from stdin, which lets
# us embed a multi-KB PR context without quoting headaches.
( cd "$GITHUB_WORKSPACE" \
  && timeout "${EFFECTIVE_TIMEOUT_MINUTES}m" \
       sprout agent \
           --workflow-config "$WORKFLOW_JSON" \
           --no-web-ui \
           --no-stream \
           --persona reviewer \
           --skip-prompt \
           --max-iterations "$EFFECTIVE_MAX_ITERATIONS" \
           --budget-usd "$EFFECTIVE_MAX_BUDGET_USD" \
           --budget-warn "$EFFECTIVE_BUDGET_WARN" \
           --output-json \
           --output-path "$SPROUT_RUN_DIR/agent-result.json" \
           --prompt-stdin \
       < "$SPROUT_RUN_DIR/prompt.md" )
sprout_exit=$?

# Post the review results regardless of sprout's exit code — the model
# may have produced valid review.json even if it timed out at the very end,
# and we don't want to lose those comments.
if [ -f "$REVIEW_JSON" ]; then
    log_ok "Reviewer produced $(jq '.comments | length' "$REVIEW_JSON" 2>/dev/null || echo 0) comments"
    review_post_results "$PR_NUMBER" "$REVIEW_JSON" "$SUMMARY_MD"
    emit_output "success=true"
else
    log_err "Reviewer did not produce $REVIEW_JSON (exit=$sprout_exit)"
    emit_output "success=false"
fi

emit_output "pr-number=$PR_NUMBER"
# Surface spend so callers can build budgets on top of this action.
emit_cost_output

[ "$sprout_exit" -eq 0 ] || exit "$sprout_exit"
}

review_main
