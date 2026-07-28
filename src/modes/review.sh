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
run_sprout_agent() {
    local prompt_file="$1"
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
           < "$prompt_file" )
    return $?
}

run_sprout_agent "$SPROUT_RUN_DIR/prompt.md" && sprout_exit=0 || sprout_exit=$?

# ── Validate-and-retry loop ──────────────────────────────────────────
#
# The agent may produce a malformed review.json — truncated output,
# markdown fences wrapping the JSON, extra prose before/after the JSON,
# or missing required fields. Instead of failing immediately, we validate
# the output and give the agent one retry with a corrective prompt that
# includes the specific validation error and a preview of the bad file.
# This catches the common failure where the model writes valid JSON but
# with schema issues (e.g., line as string instead of number, missing
# comments array).

MAX_REVIEW_RETRIES=1
retry_count=0

while [ "$retry_count" -le "$MAX_REVIEW_RETRIES" ]; do
    validation_error=""
    if [ ! -f "$REVIEW_JSON" ]; then
        validation_error="review.json was not created."
    else
        validation_error=$(review_validate_json "$REVIEW_JSON") || true
        if [ -z "$validation_error" ]; then
            break  # Valid — proceed to post
        fi
    fi

    if [ "$retry_count" -lt "$MAX_REVIEW_RETRIES" ]; then
        log_warn "review.json validation failed (attempt $((retry_count + 1))/$((MAX_REVIEW_RETRIES + 1))): $validation_error"
        log_info "Feeding validation error back to agent for corrective rewrite..."

        # Build a corrective prompt: the error + explicit instructions to
        # re-write just the review.json file correctly.
        local corrective_prompt="$SPROUT_RUN_DIR/corrective_prompt_${retry_count}.md"
        cat > "$corrective_prompt" <<CORRECTIVE_EOF
The review.json file you wrote failed validation. Fix it and re-write the file.

## Validation Error

${validation_error}

## Instructions

Read the current content of ${REVIEW_JSON} to see what went wrong, then use
write_file to overwrite it with valid JSON.

The file MUST be valid JSON (no markdown fences, no prose before or after)
with this exact schema:

\`\`\`json
{
  "summary": "One sentence string.",
  "approval_status": "approve" | "request_changes" | "comment",
  "comments": [
    {
      "file": "path/to/file",
      "line": 42,
      "body": "Issue description",
      "severity": "critical" | "major" | "minor" | "suggestion"
    }
  ]
}
\`\`\`

If you found no issues earlier, write: {"summary": "No issues found.", "approval_status": "approve", "comments": []}

Write ONLY valid JSON to ${REVIEW_JSON} — no markdown fences, no commentary.
CORRECTIVE_EOF

        run_sprout_agent "$corrective_prompt" && sprout_exit=0 || sprout_exit=$?
        retry_count=$((retry_count + 1))
    else
        # Final attempt failed — log and continue to post (which will
        # also validate, but we let review_post_results handle the final
        # error message).
        log_err "review.json still invalid after ${MAX_REVIEW_RETRIES} retries: $validation_error"
        retry_count=$((retry_count + 1))
    fi
done

# ── Post results ─────────────────────────────────────────────────────
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
