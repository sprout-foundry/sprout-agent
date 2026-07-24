#!/bin/bash
# plan.sh — planning mode. Reads an issue and produces a detailed plan
# (rendered as a markdown artifact + posted as an issue comment).
#
# Cheaper than fix mode: single LLM call (orchestrator only), no file
# mutations, no PR creation. Useful for kicking off a `/sprout-plan`
# comment to surface a structured plan before committing to the heavier
# fix run.
#
# Functions are intentionally defined after their use sites; shellcheck
# doesn't see the run-time order, so silence the cosmetic warning.
# shellcheck disable=SC2218
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"

log_info "Plan mode — bootstrapping workflow JSON"

ISSUE_NUMBER=$(event_issue_number)
if [ -z "$ISSUE_NUMBER" ]; then
    log_err "Could not determine issue number from event payload"
    emit_output "success=false"
    exit 1
fi
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    log_err "Issue number '$ISSUE_NUMBER' is not a positive integer"
    emit_output "success=false"
    exit 1
fi
log_info "Planning issue #$ISSUE_NUMBER in $GITHUB_REPOSITORY"

# Reuse the same context-fetcher as fix mode — they need the same info.
# This avoids duplication; if context-fetch changes for fix, plan benefits.
SPROUT_RUN_DIR="$SPROUT_RUN_DIR" \
GITHUB_TOKEN="$GITHUB_TOKEN" \
GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
ISSUE_NUMBER="$ISSUE_NUMBER" \
    fix_fetch_context 2>/dev/null \
    || {
        # fix_fetch_context lives in fix.sh — source it on demand so this
        # script can stand alone.
        source "$SPROUT_AGENT_MODES/fix.sh" 2>/dev/null || true
        if declare -f fix_fetch_context >/dev/null; then
            SPROUT_RUN_DIR="$SPROUT_RUN_DIR" \
            GITHUB_TOKEN="$GITHUB_TOKEN" \
            GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
            ISSUE_NUMBER="$ISSUE_NUMBER" \
                fix_fetch_context
        else
            log_err "fix_fetch_context helper unavailable; cannot build context"
            exit 1
        fi
    }

WORKFLOW_JSON="$SPROUT_RUN_DIR/workflow.json"
plan_render_workflow_json "$WORKFLOW_JSON"

PROMPT_FILE="$SPROUT_RUN_DIR/prompt.md"
{
    cat "$SPROUT_AGENT_PROMPTS/plan_prompt.md"
    printf '\n\n## Issue Context\n\n'
    cat "$SPROUT_RUN_DIR/context.md"
} > "$PROMPT_FILE"

log_info "Invoking sprout agent..."

# Fail fast if the prompt didn't get written.
if [ ! -s "$PROMPT_FILE" ]; then
    log_err "Prompt file is missing or empty — context fetch probably failed"
    emit_output "success=false"
    exit 1
fi

( cd "$GITHUB_WORKSPACE" \
  && timeout "${EFFECTIVE_TIMEOUT_MINUTES}m" \
       sprout agent \
           --workflow-config "$WORKFLOW_JSON" \
           --no-web-ui \
           --no-stream \
           --persona orchestrator \
           --skip-prompt \
           --max-iterations "$EFFECTIVE_MAX_ITERATIONS" \
           --budget-usd "$EFFECTIVE_MAX_BUDGET_USD" \
           --budget-warn "$EFFECTIVE_BUDGET_WARN" \
           --output-json \
           --output-path "$SPROUT_RUN_DIR/agent-result.json" \
           --prompt-stdin \
       < "$PROMPT_FILE" )
sprout_exit=$?

PLAN_MD="$SPROUT_RUN_DIR/plan.md"
if [ -f "$PLAN_MD" ]; then
    log_ok "Plan rendered ($(wc -c < "$PLAN_MD") bytes)"
    plan_post_comment "$ISSUE_NUMBER" "$PLAN_MD"
    emit_output "success=true"
else
    log_err "No plan.md produced (exit=$sprout_exit)"
    emit_output "success=false"
fi

emit_output "issue-number=$ISSUE_NUMBER"
emit_cost_output
[ "$sprout_exit" -eq 0 ] || exit "$sprout_exit"

# -- Mode-internal helpers -------------------------------------------------

plan_render_workflow_json() {
    local out="$1"
    jq -n \
        --arg provider "$AI_PROVIDER" \
        --arg model    "$AI_MODEL" \
        --arg repo     "${GITHUB_REPOSITORY:-unknown}" \
        --arg issue    "${ISSUE_NUMBER:-?}" \
        --argjson max  "$EFFECTIVE_MAX_ITERATIONS" \
        --argjson budget "$EFFECTIVE_MAX_BUDGET_USD" \
        --arg prompt_file "$SPROUT_RUN_DIR/prompt.md" \
        '{
            description: ("Plan issue " + $issue + " in " + $repo),
            no_web_ui: true,
            persist_runtime_overrides: false,
            continue_on_error: true,
            budget: { usd: $budget, warn_at: [0.5, 0.8], on_exceed: "truncate" },
            initial: {
                prompt_file: $prompt_file,
                provider: $provider,
                model: $model,
                persona: "orchestrator",
                skip_prompt: true,
                max_iterations: $max,
                risk_profile: "cautious"
            }
        }' > "$out"
    log_ok "Workflow JSON rendered to $out"
}

plan_post_comment() {
    local issue="$1"
    local plan_md="$2"
    local hdr=(-H "authorization: Bearer $GITHUB_TOKEN" -H "accept: application/vnd.github+json")
    local body
    body=$(jq -Rn --rawfile plan "$plan_md" \
        '{
            body: ("## Implementation Plan\n\n" + $plan + "\n\n---\n_Posted by sprout-agent. Add `/sprout-fix` to start implementing._")
        }')
    curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" -X POST \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${issue}/comments" \
        -d "$body" >/dev/null \
        || log_warn "Failed to post plan comment"
    log_ok "Plan posted to issue #$issue"
}
