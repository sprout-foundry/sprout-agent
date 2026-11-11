#!/bin/bash
# audit.sh — security audit mode. Runs sprout read-only over a checkout and
# writes the findings it reports to a JSON file for a later step to act on.
#
# The agent gets no GitHub token and no write access: whoever files issues
# from the findings does it in a separate step or job with its own token, so
# a prompt injected through the audited code can at worst skew the report.
#
# Scope:
#   audit-base-ref set   review what changed between that commit and HEAD
#   audit-paths set      review those paths in full
#   neither              review the whole checkout
#
# shellcheck shell=bash
# shellcheck disable=SC2016  # backticks in prompt text are literal
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"

audit_main() {
    local target="${AUDIT_TARGET:-.}"
    case "$target" in
        /*) ;;
        *)  target="$GITHUB_WORKSPACE/$target" ;;
    esac
    if [ ! -d "$target" ]; then
        log_err "audit-target '$target' is not a directory"
        emit_output "success=false"
        exit 1
    fi

    FINDINGS_PATH="${FINDINGS_PATH:-$SPROUT_RUN_DIR/findings.json}"
    local result_json="$SPROUT_RUN_DIR/agent-result.json"
    local prompt_file="$SPROUT_RUN_DIR/prompt.md"
    local scope_file="$SPROUT_RUN_DIR/scope.md"

    audit_write_scope "$target" "$scope_file" || {
        emit_output "success=false"
        exit 1
    }
    if [ ! -s "$scope_file" ]; then
        log_ok "Nothing changed since ${AUDIT_BASE_REF} — no audit needed"
        printf '{"findings":[]}\n' > "$FINDINGS_PATH"
        emit_output "success=true"
        emit_output "findings-path=$FINDINGS_PATH"
        emit_output "findings-count=0"
        emit_output "cost=0"
        exit 0
    fi

    # The template's ${AUDIT_SCOPE} line is replaced by the scope section.
    expand_prompt_template "$SPROUT_AGENT_PROMPTS/audit_prompt.md" \
        | awk -v scope="$scope_file" '
            $0 == "${AUDIT_SCOPE}" { while ((getline l < scope) > 0) print l; next }
            { print }' > "$prompt_file"

    log_info "Auditing $target (budget \$${EFFECTIVE_MAX_BUDGET_USD}, ${EFFECTIVE_TIMEOUT_MINUTES}m)"

    # Strip every credential the agent does not need. Provider keys stay:
    # the model call needs them.
    local sprout_exit=0
    ( cd "$target" \
      && env -u GITHUB_TOKEN -u GH_TOKEN -u GH_ENTERPRISE_TOKEN \
             -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
             -u ACTIONS_ID_TOKEN_REQUEST_URL \
         timeout "${EFFECTIVE_TIMEOUT_MINUTES}m" \
           sprout agent \
               --no-web-ui \
               --no-daemon \
               --no-stream \
               --no-subagents \
               --no-project-skills \
               --yes \
               --risk-profile readonly \
               --provider "$AI_PROVIDER" \
               --model "$AI_MODEL" \
               --max-iterations "$EFFECTIVE_MAX_ITERATIONS" \
               --budget-usd "$EFFECTIVE_MAX_BUDGET_USD" \
               --budget-warn "$EFFECTIVE_BUDGET_WARN" \
               --json \
               -o "$result_json" \
               --prompt-stdin \
           < "$prompt_file" ) || sprout_exit=$?

    emit_cost_output "$result_json"

    if audit_extract_findings "$result_json" "$FINDINGS_PATH"; then
        local count
        count=$(jq '.findings | length' "$FINDINGS_PATH")
        log_ok "$count finding(s) written to $FINDINGS_PATH"
        emit_output "success=true"
        emit_output "findings-path=$FINDINGS_PATH"
        emit_output "findings-count=$count"
        exit 0
    fi

    log_err "No valid findings block in the agent's answer (sprout exit=$sprout_exit)"
    log_err "Raw answer kept at $SPROUT_RUN_DIR/answer.md"
    emit_output "success=false"
    emit_output "findings-path="
    emit_output "findings-count="
    exit 1
}

# audit_write_scope TARGET OUT — write the prompt's scope section to OUT.
# Leaves OUT empty when a base ref is given and nothing changed since it.
audit_write_scope() {
    local target="$1" out="$2"
    : > "$out"

    if [ -n "${AUDIT_INSTRUCTIONS_FILE:-}" ]; then
        if [ ! -f "$AUDIT_INSTRUCTIONS_FILE" ]; then
            log_err "audit-instructions-file '$AUDIT_INSTRUCTIONS_FILE' not found"
            return 1
        fi
        {
            printf '## Project context\n\n'
            cat "$AUDIT_INSTRUCTIONS_FILE"
            printf '\n\n'
        } >> "$out"
    fi

    if [ -n "${AUDIT_BASE_REF:-}" ]; then
        if ! git -C "$target" cat-file -e "${AUDIT_BASE_REF}^{commit}" 2>/dev/null; then
            log_err "audit-base-ref '$AUDIT_BASE_REF' is not a commit in the checkout (fetch with enough depth)"
            return 1
        fi
        local files="$SPROUT_RUN_DIR/changed-files.txt"
        git -C "$target" diff --name-only --diff-filter=AMR "$AUDIT_BASE_REF" HEAD > "$files"
        if [ ! -s "$files" ]; then
            : > "$out"
            return 0
        fi
        {
            printf '## Scope\n\n'
            printf 'Review the changes between commit %s and HEAD. ' "$AUDIT_BASE_REF"
            printf 'See them with `git diff %s HEAD -- <file>`. ' "$AUDIT_BASE_REF"
            printf 'Read the surrounding code a change depends on (callers, middleware, '
            printf 'the handler a route reaches) to judge it, but report only problems '
            printf 'the changes introduce or expose.\n\nChanged files:\n\n'
            head -n 400 "$files" | sed 's/^/- /'
            [ "$(wc -l < "$files")" -le 400 ] \
                || printf '\n(list cut at 400 files; run `git diff --name-only %s HEAD` for the rest)\n' "$AUDIT_BASE_REF"
        } >> "$out"
    elif [ -n "${AUDIT_PATHS:-}" ]; then
        {
            printf '## Scope\n\n'
            printf 'Review these paths in full, following calls into other code as needed:\n\n'
            printf '%s\n' "$AUDIT_PATHS" | tr ' ' '\n' | sed '/^$/d; s/^/- /'
        } >> "$out"
    else
        printf '## Scope\n\nReview the whole repository. Start from its entry points (servers, CLIs, workflows, manifests) and the code that handles untrusted input.\n' >> "$out"
    fi
}

# audit_extract_findings RESULT OUT — take the last fenced json block (or
# the whole answer, if it is JSON) from sprout's result and write the valid
# findings to OUT. Invalid entries are dropped with a warning.
audit_extract_findings() {
    local result="$1" out="$2"
    local answer="$SPROUT_RUN_DIR/answer.md" block="$SPROUT_RUN_DIR/answer-block.json"
    [ -f "$result" ] || return 1
    jq -r '.response // empty' "$result" > "$answer" 2>/dev/null || return 1
    [ -s "$answer" ] || return 1

    awk '
        /^[[:space:]]*```(json)?[[:space:]]*$/ {
            if (inside) { inside = 0; last = cur; cur = "" } else { inside = 1; cur = "" }
            next
        }
        inside { cur = cur $0 "\n" }
        END { printf "%s", last }' "$answer" > "$block"
    if ! jq -e 'type == "object"' "$block" >/dev/null 2>&1; then
        jq -e 'type == "object"' "$answer" >/dev/null 2>&1 || return 1
        cp "$answer" "$block"
    fi

    jq -e '.findings | type == "array"' "$block" >/dev/null 2>&1 || return 1
    jq '{
        findings: [ .findings[]
            | select(type == "object")
            | select((.rule | type) == "string" and (.rule | length) > 0)
            | select((.title | type) == "string" and (.title | length) > 0)
            | select((.file | type) == "string" and (.file | length) > 0)
            | select(.severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "low")
            | {
                rule: (.rule | ascii_downcase | gsub("[^a-z0-9-]+"; "-")),
                severity,
                title: (.title | .[0:200]),
                file: (.file | ltrimstr("./")),
                line: (if (.line | type) == "number" then .line else null end),
                category: ((.category // "other") | tostring),
                description: ((.description // "") | tostring),
                recommendation: ((.recommendation // "") | tostring),
                confidence: (if .confidence == "high" or .confidence == "medium" then .confidence else "medium" end)
              } ]
    }' "$block" > "$out"

    local raw kept
    raw=$(jq '.findings | length' "$block")
    kept=$(jq '.findings | length' "$out")
    [ "$raw" -eq "$kept" ] || log_warn "Dropped $((raw - kept)) malformed finding(s)"
    return 0
}

# The self-test sources this file for the helpers alone.
[ "${SPROUT_AUDIT_NO_MAIN:-}" = 1 ] || audit_main
