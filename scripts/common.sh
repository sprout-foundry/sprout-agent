#!/bin/bash
# common.sh — shared helpers sourced by every script in this action.
#
# Sets sane defaults, exports common paths, and provides log helpers. Keep
# this file small and side-effect-light: source it as `source common.sh` from
# sibling scripts.
set -euo pipefail

# Resolve the action root once. Other scripts reference workflows/prompts
# relative to this, so the action can run from any CWD inside the workflow.
SPROUT_AGENT_PATH="${SPROUT_AGENT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SPROUT_AGENT_PATH
export SPROUT_AGENT_SCRIPTS="$SPROUT_AGENT_PATH/scripts"
export SPROUT_AGENT_MODES="$SPROUT_AGENT_PATH/src/modes"
export SPROUT_AGENT_WORKFLOWS="$SPROUT_AGENT_PATH/src/workflows"
export SPROUT_AGENT_PROMPTS="$SPROUT_AGENT_PATH/src/prompts"

# Sprout's config + state dirs. SPROUT_CONFIG is honored by sprout natively;
# we keep both knobs exposed because users often pin config per-repo.
SPROUT_CONFIG="${SPROUT_CONFIG:-$HOME/.config/sprout}"
export SPROUT_CONFIG

# Log helpers. Use ASCII glyphs only — some CI runners strip emoji. Color
# codes are guarded by isatty so logs on GitHub stay readable.
_log_color() {
    if [ -t 1 ]; then
        case "$1" in
            info)    printf '\033[0;34m' ;;
            ok)      printf '\033[0;32m' ;;
            warn)    printf '\033[0;33m' ;;
            err)     printf '\033[0;31m' ;;
            *)       printf '\033[0m' ;;
        esac
    fi
}

log_info()  { _log_color info ; printf '[sprout-agent] %s\n' "$*" >&2 ; _log_color reset ; }
log_ok()    { _log_color ok ; printf '[sprout-agent] %s\n' "$*" >&2 ; _log_color reset ; }
log_warn()  { _log_color warn ; printf '[sprout-agent] %s\n' "$*" >&2 ; _log_color reset ; }
log_err()   { _log_color err ; printf '[sprout-agent] %s\n' "$*" >&2 ; _log_color reset ; }
log_debug() { [ "${DEBUG:-false}" = "true" ] && log_info "debug: $*" || true ; }

# Resolve mode-derived defaults. Most callers leave them unset and let the
# per-mode script pick the right one. This lives here so the same logic isn't
# duplicated across dispatch.sh / review.sh / fix.sh.
default_max_iterations() {
    case "${MODE:-review}" in
        review) echo 120 ;;
        fix)    echo 240 ;;
        plan)   echo 60 ;;
        *)      echo 120 ;;
    esac
}

default_budget_usd() {
    case "${MODE:-review}" in
        review) echo 2.00 ;;
        fix)    echo 8.00 ;;
        plan)   echo 1.00 ;;
        *)      echo 2.00 ;;
    esac
}

default_timeout_minutes() {
    case "${MODE:-review}" in
        review) echo 15 ;;
        fix)    echo 45 ;;
        plan)   echo 10 ;;
        *)      echo 15 ;;
    esac
}

default_trigger_phrase() {
    case "${MODE:-review}" in
        review) echo "/sprout-review" ;;
        fix)    echo "/sprout-fix" ;;
        plan)   echo "/sprout-plan" ;;
        *)      echo "/sprout-${MODE:-review}" ;;
    esac
}

# Resolve effective values for the run. Empty inputs fall through to defaults.
EFFECTIVE_MAX_ITERATIONS="${MAX_ITERATIONS:-$(default_max_iterations)}"
EFFECTIVE_MAX_BUDGET_USD="${MAX_BUDGET_USD:-$(default_budget_usd)}"
EFFECTIVE_BUDGET_WARN="${BUDGET_WARN:-0.5,0.8}"
EFFECTIVE_TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-$(default_timeout_minutes)}"
EFFECTIVE_TRIGGER_PHRASE="${TRIGGER_PHRASE:-$(default_trigger_phrase)}"
EFFECTIVE_MCP="${MCP:-$( [ "${MODE:-review}" = "fix" ] && echo "github" || echo "off" )}"

export EFFECTIVE_MAX_ITERATIONS
export EFFECTIVE_MAX_BUDGET_USD
export EFFECTIVE_BUDGET_WARN
export EFFECTIVE_TIMEOUT_MINUTES
export EFFECTIVE_TRIGGER_PHRASE
export EFFECTIVE_MCP

# Resolve outputs dir. Each run gets a unique subdir so concurrent runs
# (e.g. workflow_dispatch + a comment) don't trample each other's files.
# Use intermediate variables to avoid nested-${}…${}…} parameter-expansion
# precedence ambiguity in bash 4.4+.
_sprout_run_id="${GITHUB_RUN_ID:-$$}"
_sprout_run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
SPROUT_RUN_DIR="${SPROUT_RUN_DIR:-/tmp/sprout-run-${_sprout_run_id}-${_sprout_run_attempt}}"
SPROUT_RUN_DIR="${SPROUT_RUN_DIR//[[:space:]]/_}"
export SPROUT_RUN_DIR
unset _sprout_run_id _sprout_run_attempt

# Best-effort: prune run dirs older than 7 days so /tmp doesn't fill up
# on long-lived self-hosted runners. We only touch directories we created
# (matching sprout-run-*) so concurrent runs and unrelated tmp files are
# unaffected.
find /tmp -maxdepth 1 -type d -name 'sprout-run-*' -mtime +7 \
    -exec rm -rf {} + 2>/dev/null || true

mkdir -p "$SPROUT_RUN_DIR"

# Look up a PR/issue number from the event payload. Used by review/fix shells.
# Returns empty string when not applicable.
event_pr_number() {
    local event_name="${GITHUB_EVENT_NAME:-}"
    local event_path="${GITHUB_EVENT_PATH:-}"
    [ -z "$event_path" ] && return 0
    case "$event_name" in
        pull_request)
            jq -r '.pull_request.number // empty' "$event_path"
            ;;
        pull_request_review_comment)
            # Inline review comment thread; the PR number is on
            # .pull_request.number. Without this, /sprout-review
            # comments on a specific line are silently ignored.
            jq -r '.pull_request.number // empty' "$event_path"
            ;;
        issue_comment)
            # Set on PR comments too — `.issue.pull_request` is non-null there.
            jq -r 'if (.issue.pull_request // null) != null then .issue.number else empty end' "$event_path"
            ;;
        issues)
            jq -r '.issue.number // empty' "$event_path"
            ;;
        workflow_dispatch)
            jq -r '.inputs.pr_number // .inputs.issue_number // empty' "$event_path"
            ;;
        *) echo "" ;;
    esac
}

event_issue_number() {
    local event_name="${GITHUB_EVENT_NAME:-}"
    local event_path="${GITHUB_EVENT_PATH:-}"
    [ -z "$event_path" ] && return 0
    case "$event_name" in
        issue_comment)
            jq -r '.issue.number // empty' "$event_path"
            ;;
        issues)
            jq -r '.issue.number // empty' "$event_path"
            ;;
        workflow_dispatch)
            jq -r '.inputs.issue_number // empty' "$event_path"
            ;;
        *) echo "" ;;
    esac
}

event_comment_body() {
    local event_path="${GITHUB_EVENT_PATH:-}"
    [ -z "$event_path" ] && return 0
    jq -r '.comment.body // empty' "$event_path" 2>/dev/null || echo ""
}

# Emit a `$GITHUB_OUTPUT` line. Multiple invocations append, so callers
# inside loops should group values. Bash is fine because we never need
# JSON encoding — these are all scalars.
emit_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s\n' "$*" >> "$GITHUB_OUTPUT"
    fi
    log_debug "output: $*"
}

# expand_prompt_template — read a prompt template from $1 and substitute
# ${VAR} style references using the current environment. The result is
# printed to stdout.
#
# Prompt templates use ${SPROUT_RUN_DIR}, ${PR_NUMBER}, ${ISSUE_NUMBER},
# ${GITHUB_REPOSITORY}, ${GITHUB_WORKSPACE}, ${BRANCH_NAME} as
# placeholders. Without this substitution the agent sees literal
# ${SPROUT_RUN_DIR}/review.json and has to guess the actual path.
expand_prompt_template() {
    local template="$1"
    sed \
        -e "s|\${SPROUT_RUN_DIR}|${SPROUT_RUN_DIR:-}|g" \
        -e "s|\${PR_NUMBER}|${PR_NUMBER:-}|g" \
        -e "s|\${ISSUE_NUMBER}|${ISSUE_NUMBER:-}|g" \
        -e "s|\${GITHUB_REPOSITORY}|${GITHUB_REPOSITORY:-}|g" \
        -e "s|\${GITHUB_WORKSPACE}|${GITHUB_WORKSPACE:-}|g" \
        -e "s|\${BRANCH_NAME}|${BRANCH_NAME:-}|g" \
        "$template"
}

# emit_cost_output — extract USD cost from sprout's agent-result JSON and
# emit it as the `cost` action output.
#
# Sprout writes a structured result when invoked with --output-json +
# --output-path. The cost lives at `.metrics.cost` (USD, float).
#
# Tolerates:
#   - Missing file (sprout didn't write it because of an early failure)
#   - Malformed JSON (jq returns non-zero; we don't want to crash the run)
#   - Zero / empty cost (e.g. provider returned no usage data)
# We never fail the workflow for cost-tracking issues.
emit_cost_output() {
    local result_json="${1:-$SPROUT_RUN_DIR/agent-result.json}"
    local cost=""

    if [ -f "$result_json" ]; then
        cost=$(jq -r '.metrics.cost // empty' "$result_json" 2>/dev/null || true)
    fi

    # Emit empty when truly absent (no JSON, no .metrics.cost). Otherwise
    # pass through whatever value sprout reported — including a legitimate
    # 0.00 from a free-tier call. `awk` does the numeric positivity check
    # without tripping on "0.00" vs "0" string comparisons.
    if [ -n "$cost" ] && [ "$cost" != "null" ] && awk -v c="$cost" 'BEGIN { exit !(c+0 >= 0) }'; then
        emit_output "cost=$cost"
        log_info "Run cost: \$${cost}"
    else
        emit_output "cost="
        log_debug "Cost not reported (no agent-result.json or .metrics.cost absent)"
    fi
}
