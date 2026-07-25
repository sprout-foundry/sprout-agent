#!/bin/bash
# fix.sh — implementor mode. Context-aware: works on issues AND PRs.
#
# When triggered on an issue (/sprout-fix on issue comment):
#   1. Fetch issue context (body + comments + linked PRs + images)
#   2. Create branch issue/NNN
#   3. Run the orchestrator → coder → tester → reviewer → build → fix loop
#   4. Commit to issue/NNN and open a new PR
#
# When triggered on a PR (/sprout-fix on PR comment or review comment):
#   1. Fetch PR context (body + reviews + inline review comments + diff)
#   2. Checkout the PR's existing head branch
#   3. Run the orchestrator → coder → tester → reviewer → build → fix loop
#   4. Commit to the existing PR branch (no new PR created)
#
# The same /sprout-fix command does the right thing based on context.
#
# shellcheck shell=bash
# shellcheck disable=SC2218
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"

fix_main() {
log_info "Fix mode — bootstrapping workflow JSON"

# --- Context detection: issue vs PR ---
detect_fix_context

if [ -z "$FIX_NUMBER" ]; then
    log_err "Could not determine issue or PR number from event payload"
    log_err "Event: ${GITHUB_EVENT_NAME:-<unset>}"
    emit_output "success=false"
    exit 1
fi
if ! [[ "$FIX_NUMBER" =~ ^[0-9]+$ ]]; then
    log_err "Number '$FIX_NUMBER' is not a positive integer"
    emit_output "success=false"
    exit 1
fi

# Set ISSUE_NUMBER for expand_prompt_template and workflow JSON backward compat.
ISSUE_NUMBER="$FIX_NUMBER"
export ISSUE_NUMBER

if [ "$FIX_TARGET" = "pr" ]; then
    log_info "Fix mode (PR) — addressing review findings on PR #$FIX_NUMBER in $GITHUB_REPOSITORY"

    # Resolve the PR's head branch via API.
    BRANCH_NAME=$(resolve_pr_head_ref)
    if [ -z "$BRANCH_NAME" ]; then
        log_err "Could not resolve head ref for PR #$FIX_NUMBER"
        emit_output "success=false"
        exit 1
    fi
    FIX_BRANCH="$BRANCH_NAME"
    export FIX_BRANCH
    log_info "PR head branch: $BRANCH_NAME"

    # Fetch PR context: reviews, inline comments, diff, issue comments.
    fix_fetch_pr_context

    # Checkout the PR's existing branch — no new branch creation.
    fix_checkout_pr_branch "$BRANCH_NAME"

    PROMPT_TEMPLATE="$SPROUT_AGENT_PROMPTS/fix_pr_initial_prompt.md"
else
    log_info "Fix mode (issue) — implementing issue #$FIX_NUMBER in $GITHUB_REPOSITORY"

    # Fetch issue context (body, comments, linked PRs, attached images).
    SPROUT_RUN_DIR="$SPROUT_RUN_DIR" \
    GITHUB_TOKEN="$GITHUB_TOKEN" \
    GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
    ISSUE_NUMBER="$ISSUE_NUMBER" \
        fix_fetch_context

    # Create + checkout the issue branch.
    BRANCH_NAME="$FIX_BRANCH"
    fix_setup_branch "$BRANCH_NAME"

    PROMPT_TEMPLATE="$SPROUT_AGENT_PROMPTS/fix_initial_prompt.md"
fi

# --- Render workflow JSON ---
WORKFLOW_JSON="$SPROUT_RUN_DIR/workflow.json"
fix_render_workflow_json "$WORKFLOW_JSON"

# --- Compose the prompt ---
PROMPT_FILE="$SPROUT_RUN_DIR/prompt.md"
{
    expand_prompt_template "$PROMPT_TEMPLATE"
    printf '\n\n## Context\n\n'
    cat "$SPROUT_RUN_DIR/context.md"
} > "$PROMPT_FILE"

# Append the trigger comment text so the agent can pick up any
# specific instructions the user included alongside /sprout-fix.
if [ -n "${FIX_TRIGGER_COMMENT:-}" ]; then
    # Strip the trigger phrase itself, keep any additional guidance.
    local extra
    extra=$(printf '%s' "$FIX_TRIGGER_COMMENT" | sed "s|${EFFECTIVE_TRIGGER_PHRASE}||g" | sed 's/^ *//;s/ *$//')
    if [ -n "$extra" ]; then
        printf '\n\n## Additional Guidance from Trigger Comment\n\n%s\n' "$extra" >> "$PROMPT_FILE"
    fi
fi

log_info "Invoking sprout agent..."
log_info "Command: timeout ${EFFECTIVE_TIMEOUT_MINUTES}m sprout agent --workflow-config $WORKFLOW_JSON --prompt-stdin < $PROMPT_FILE"

if [ ! -s "$PROMPT_FILE" ]; then
    log_err "Prompt file $PROMPT_FILE is missing or empty — context fetch probably failed"
    log_err "See $SPROUT_RUN_DIR for partial outputs"
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

# --- Post-agent: commit + (create PR for issues / push for PRs) ---
if [ -n "$(cd "$GITHUB_WORKSPACE" && git status --porcelain 2>/dev/null)" ]; then
    if [ "$FIX_TARGET" = "pr" ]; then
        log_info "Detected changes on PR branch $BRANCH_NAME — committing + pushing"
        fix_commit_to_pr "$BRANCH_NAME"
    else
        log_info "Detected changes on $BRANCH_NAME — creating commit + PR"
        fix_commit_and_pr "$BRANCH_NAME"
    fi
    emit_output "success=true"
else
    log_warn "No changes to commit"
    emit_output "success=false"
fi

emit_output "branch-name=$BRANCH_NAME"

if [ "$FIX_TARGET" = "pr" ]; then
    # PR mode: we pushed to an existing PR — report the PR number.
    emit_output "pr-number=$FIX_NUMBER"
    emit_output "pr-url=https://github.com/${GITHUB_REPOSITORY}/pull/${FIX_NUMBER}"
else
    emit_output "pr-number=$(jq -r '.number // empty' "$SPROUT_RUN_DIR/pr.json" 2>/dev/null || true)"
    emit_output "pr-url=$(jq -r '.url // empty' "$SPROUT_RUN_DIR/pr.json" 2>/dev/null || true)"
fi

emit_cost_output

[ "$sprout_exit" -eq 0 ] || exit "$sprout_exit"
}

# =========================================================================
# PR-mode helpers
# =========================================================================

# fix_fetch_pr_context — pull PR metadata, reviews, inline review comments,
# issue comments, and the diff. Writes context.md + prompt.md inputs.
#
# This is what makes /sprout-fix on a PR useful: the agent sees exactly
# what the reviewer flagged (both review verdicts and inline comments) and
# works from that.
fix_fetch_pr_context() {
    local pr="$FIX_NUMBER"
    local repo="$GITHUB_REPOSITORY"
    local token="$GITHUB_TOKEN"
    local out="$SPROUT_RUN_DIR"
    local hdr=()
    [ -n "$token" ] && hdr=(-H "authorization: Bearer $token" -H "accept: application/vnd.github+json")

    log_info "Fetching PR #$pr metadata..."

    local meta
    if ! meta=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr}"); then
        log_err "Failed to fetch PR #$pr metadata"
        emit_output "success=false"
        exit 1
    fi

    local title body base sha state author url
    title=$(printf '%s' "$meta" | jq -r '.title')
    body=$(printf '%s' "$meta" | jq -r '.body // ""')
    base=$(printf '%s' "$meta" | jq -r '.base.ref')
    sha=$(printf '%s' "$meta" | jq -r '.head.sha')
    state=$(printf '%s' "$meta" | jq -r '.state')
    author=$(printf '%s' "$meta" | jq -r '.user.login')
    url=$(printf '%s' "$meta" | jq -r '.html_url')

    log_info "PR: $title (state=$state, base=$base, head=$sha, author=$author)"

    # Diff — prefer git on-disk (cheap), fall back to API.
    local diff_file="$out/full.diff"
    if [ -d "$GITHUB_WORKSPACE/.git" ] && \
       git -C "$GITHUB_WORKSPACE" rev-parse --verify --quiet "$sha" >/dev/null 2>&1; then
        log_info "Computing diff via git..."
        if ! git -C "$GITHUB_WORKSPACE" diff --unified=3 "${base}...${sha}" > "$diff_file" 2>/dev/null; then
            log_warn "git diff failed; falling back to API"
            curl --fail --show-error --silent --max-time 60 \
                -H "accept: application/vnd.github.v3.diff" \
                "${hdr[@]}" \
                "https://api.github.com/repos/${repo}/pulls/${pr}.diff" > "$diff_file"
        fi
    else
        log_info "Computing diff via GitHub API..."
        curl --fail --show-error --silent --max-time 60 \
            -H "accept: application/vnd.github.v3.diff" \
            "${hdr[@]}" \
            "https://api.github.com/repos/${repo}/pulls/${pr}.diff" > "$diff_file"
    fi
    local diff_lines
    diff_lines=$(wc -l < "$diff_file" 2>/dev/null || echo 0)
    log_info "Diff: $diff_lines lines"

    # Reviews — verdicts with bodies (APPROVE / REQUEST_CHANGES / COMMENTED).
    log_info "Fetching PR reviews..."
    local reviews
    reviews=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr}/reviews?per_page=100&paginate=true" || echo "[]")
    local reviews_count
    reviews_count=$(printf '%s' "$reviews" | jq 'length')
    log_info "Reviews: $reviews_count"

    # Inline review comments — file, line, body, author. These are the
    # specific findings the reviewer posted on lines of code.
    log_info "Fetching inline review comments..."
    local review_comments
    review_comments=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr}/comments?per_page=100&paginate=true" || echo "[]")
    local review_comments_count
    review_comments_count=$(printf '%s' "$review_comments" | jq 'length')
    log_info "Inline review comments: $review_comments_count"

    # Issue comments — general PR conversation.
    log_info "Fetching issue comments..."
    local issue_comments
    issue_comments=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${pr}/comments?per_page=100&paginate=true" || echo "[]")

    # Render context.md
    {
        printf '# PR Fix Context: %s\n\n' "$title"
        printf '**PR**: %s\n' "$url"
        printf '**Author**: @%s\n' "$author"
        printf '**Base**: %s\n' "$base"
        printf '**State**: %s\n' "$state"
        printf '**Head SHA**: %s\n\n' "$sha"
        printf '## PR Description\n\n%s\n\n' "$body"

        printf '## Review Verdicts (%s)\n\n' "$reviews_count"
        if [ "$reviews_count" -gt 0 ]; then
            printf '%s\n\n' \
                "$(printf '%s' "$reviews" | jq -r \
                    '.[] | "### @\(.user.login) — \(.state)\n\(.body // \"(no body)\")\n---\n"')"
        else
            printf '(no reviews yet)\n\n'
        fi

        printf '## Inline Review Comments (%s)\n\n' "$review_comments_count"
        if [ "$review_comments_count" -gt 0 ]; then
            printf 'These are the specific code-level findings from reviewers.\n'
            printf 'Address each one unless it is clearly invalid.\n\n'
            printf '%s\n\n' \
                "$(printf '%s' "$review_comments" | jq -r \
                    '.[] | "### `\(.path):\(.line // .original_line)` — @\(.user.login)\n\(.body)\n---\n"')"
        else
            printf '(no inline review comments)\n\n'
        fi

        printf '## Issue Comments (%s)\n\n' "$(printf '%s' "$issue_comments" | jq 'length')"
        printf '%s\n\n' \
            "$(printf '%s' "$issue_comments" | jq -r \
                '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n---\n"')"

        printf '## Diff\n\nThe unified diff is at full.diff (%s lines).\n' "$diff_lines"
    } > "$out/context.md"

    log_ok "PR context ready ($(wc -c < "$out/context.md") bytes; $reviews_count reviews, $review_comments_count inline comments, $diff_lines diff lines)"
}

# fix_checkout_pr_branch — checkout the PR's existing head branch.
# Does NOT create a new branch. Installs a credential helper for push.
fix_checkout_pr_branch() {
    local branch="$1"
    (
        cd "$GITHUB_WORKSPACE"

        git config user.email  "sprout-agent[bot]@users.noreply.github.com"
        git config user.name   "sprout-agent[bot]"

        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
        fi

        # Fetch the branch from origin (it may not be in the local checkout
        # depending on the ref the workflow checked out).
        git fetch origin "$branch" 2>/dev/null || true

        if git rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
            git checkout -B "$branch" "origin/$branch"
        elif git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
            git checkout "$branch"
        else
            log_warn "Branch '$branch' not found locally or on origin; staying on current HEAD"
        fi

        log_ok "On branch $branch"
    )
}

# fix_commit_to_pr — commit changes and push to the existing PR branch.
# Does NOT create a new PR. Posts a summary comment on the PR.
fix_commit_to_pr() {
    local branch="$1"
    (
        cd "$GITHUB_WORKSPACE"

        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
        fi

        git add -A
        if [ -n "$(git status --porcelain)" ]; then
            git commit -m "sprout: address review findings on PR #${FIX_NUMBER}

Auto-generated by sprout-agent /sprout-fix." 2>&1 | head -5 || true

            local push_log="$SPROUT_RUN_DIR/git-push.log"
            git push origin "$branch" >> "$push_log" 2>&1
            local push_exit=$?
            [ "$push_exit" -eq 0 ] || log_warn "git push exit=$push_exit (see $push_log)"
        fi

        # Post a summary comment on the PR.
        curl --fail --show-error --silent --max-time 30 \
            -H "authorization: Bearer $GITHUB_TOKEN" \
            -H "accept: application/vnd.github+json" \
            -X POST \
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${FIX_NUMBER}/comments" \
            -d "$(jq -n --arg body "sprout-agent has addressed review findings and pushed updates to this PR." '{body: $body}')" \
            >/dev/null 2>&1 || true

        git config --unset credential.helper 2>/dev/null || true
    )
    log_ok "Changes pushed to PR branch $branch"
}

# =========================================================================
# Issue-mode helpers (unchanged from original)
# =========================================================================

# fix_fetch_context — pull issue metadata, comments, linked PRs, attached
# images. Writes to $SPROUT_RUN_DIR.
fix_fetch_context() {
    local issue="$ISSUE_NUMBER"
    local repo="$GITHUB_REPOSITORY"
    local token="$GITHUB_TOKEN"
    local out="$SPROUT_RUN_DIR"
    local hdr=()
    [ -n "$token" ] && hdr=(-H "authorization: Bearer $token" -H "accept: application/vnd.github+json")

    log_info "Fetching issue #$issue metadata..."

    local issue_meta
    issue_meta=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${issue}")
    local title body state author labels
    title=$(printf '%s' "$issue_meta" | jq -r '.title')
    body=$(printf '%s' "$issue_meta" | jq -r '.body // ""')
    state=$(printf '%s' "$issue_meta" | jq -r '.state')
    author=$(printf '%s' "$issue_meta" | jq -r '.user.login')
    labels=$(printf '%s' "$issue_meta" | jq -r '.labels[].name' | paste -sd', ' -)

    log_info "Issue: $title (state=$state, author=@$author, labels=$labels)"

    local comments
    comments=$(curl --fail --show-error --silent --max-time 60 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${issue}/comments?per_page=100&paginate=true" || echo "[]")

    log_info "Resolving linked pull requests..."
    local timeline
    timeline=$(curl --fail --show-error --silent --max-time 60 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${issue}/timeline?per_page=100&paginate=true" || echo "[]")
    local linked_prs
    linked_prs=$(printf '%s' "$timeline" \
        | jq '[.[] | select(.event == "cross-referenced" and (.source.issue.pull_request // null) != null) | .source.issue] | unique_by(.number)')
    log_info "Linked via timeline: $(printf '%s' "$linked_prs" | jq 'length')"

    mkdir -p "$out/images"
    local image_urls
    image_urls=$(printf '%s\n%s' "$body" "$(printf '%s' "$comments" | jq -r '.[] | .body // ""')" \
        | grep -oE 'https?://[^[:space:]]+\.(png|jpg|jpeg|gif|webp|svg)' \
        | sort -u || true)
    if [ -n "$image_urls" ]; then
        log_info "Downloading $(printf '%s\n' "$image_urls" | wc -l) attached images..."
        local n=0
        while read -r url; do
            [ -z "$url" ] && continue
            n=$((n + 1))
            local ext="${url##*.}"
            ext="${ext%%\?*}"
            case "$ext" in
                png|jpg|jpeg|gif|webp|svg) ;;
                *) ext="png" ;;
            esac
            local fname="image_${n}.${ext}"
            if [[ "$url" =~ ^https?:// ]]; then
                if ! echo "$url" | grep -qE '://(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|::1|[fF][cC]|[fF][eE][80-9a-f]:)'; then
                    if ! curl --fail --show-error --silent --max-time 30 \
                        --max-filesize 10485760 \
                        -o "$out/images/$fname" "$url"; then
                        log_warn "Failed to download $url"
                        rm -f "$out/images/$fname"
                    fi
                else
                    log_warn "Refusing to download from private network: $url"
                fi
            else
                log_warn "Refusing non-http(s) image URL: $url"
            fi
        done <<< "$image_urls"
    fi

    {
        printf '# Issue #%s: %s\n\n' "$issue" "$title"
        printf '**Repository**: %s\n' "$repo"
        printf '**State**: %s\n' "$state"
        printf '**Author**: @%s\n' "$author"
        printf '**Labels**: %s\n\n' "$labels"
        printf '**URL**: https://github.com/%s/issues/%s\n\n' "$repo" "$issue"
        printf '## Description\n\n%s\n\n' "$body"
        printf '## Comments (%s)\n\n' "$(printf '%s' "$comments" | jq 'length')"
        printf '%s\n\n' \
            "$(printf '%s' "$comments" | jq -r '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n---\n"')"
        printf '## Linked Pull Requests (%s)\n\n' \
            "$(printf '%s' "$linked_prs" | jq 'length')"
        if [ "$(printf '%s' "$linked_prs" | jq 'length')" -gt 0 ]; then
            while read -r pr; do
                local n t u
                n=$(printf '%s' "$pr" | jq -r '.number')
                t=$(printf '%s' "$pr" | jq -r '.title')
                u=$(printf '%s' "$pr" | jq -r '.html_url')
                printf -- '- #%s: %s\n' "$n" "$t"
                printf '  %s\n\n' "$u"
                local inline
                inline=$(curl --fail --show-error --silent --max-time 30 \
                    "${hdr[@]}" \
                    "https://api.github.com/repos/${repo}/pulls/${n}/comments" 2>/dev/null || echo "[]")
                if [ "$(printf '%s' "$inline" | jq 'length')" -gt 0 ]; then
                    printf -- '  - Inline comments (%s):\n' "$(printf '%s' "$inline" | jq 'length')"
                    printf '%s\n' \
                        "$(printf '%s' "$inline" | jq -r '.[] | "    - `\(.path):\(.line // .original_line)`: \(.body)\n"')"
                fi
            done < <(printf '%s' "$linked_prs" | jq -c '.[]')
        else
            printf '(none)\n\n'
        fi
        if [ -d "$out/images" ] && [ "$(ls -A "$out/images" 2>/dev/null)" ]; then
            printf '## Attached Images\n\n'
            ls -1 "$out/images" | sed 's/^/- /'
            printf '\nImages are saved under %s/images/ and can be analyzed with vision tools.\n\n' "$out"
        fi
    } > "$out/context.md"

    log_ok "Context ready ($(wc -c < "$out/context.md") bytes, $(ls "$out/images" 2>/dev/null | wc -l) images)"
}

# fix_setup_branch — create-or-checkout the issue branch and ensure it's
# pushed. Only used in issue mode.
fix_setup_branch() {
    local branch="$1"
    ( cd "$GITHUB_WORKSPACE"

        git config user.email  "sprout-agent[bot]@users.noreply.github.com"
        git config user.name   "sprout-agent[bot]"

        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
            trap 'git config --unset credential.helper 2>/dev/null || true' RETURN
        fi

        if git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
            git checkout "$branch"
        else
            git checkout -b "$branch"
        fi

        local push_log="$SPROUT_RUN_DIR/git-push.log"
        local push_exit
        git push -u origin "$branch" > "$push_log" 2>&1
        push_exit=$?
        if [ "$push_exit" -ne 0 ]; then
            log_warn "git push exit=$push_exit (see $push_log)"
        fi
    )
    log_ok "On branch $branch"
}

# fix_render_workflow_json — emit the AgentWorkflowConfig for the implementor.
# Shared by both issue and PR modes. The step chain is identical; only the
# prompt and context differ.
fix_render_workflow_json() {
    local out="$1"

    local overrides='{}'
    if [ -n "${CODER_PROVIDER:-}${CODER_MODEL:-}" ]; then
        overrides=$(printf '%s' "$overrides" | jq \
            --arg p "${CODER_PROVIDER:-$AI_PROVIDER}" \
            --arg m "${CODER_MODEL:-$AI_MODEL}" \
            '.coder = {provider: $p, model: $m}')
    fi
    if [ -n "${REVIEWER_PROVIDER:-}${REVIEWER_MODEL:-}" ]; then
        overrides=$(printf '%s' "$overrides" | jq \
            --arg p "${REVIEWER_PROVIDER:-$AI_PROVIDER}" \
            --arg m "${REVIEWER_MODEL:-$AI_MODEL}" \
            '.reviewer = {provider: $p, model: $m}')
    fi

    local build_cmd
    if [ -f "$GITHUB_WORKSPACE/go.mod" ]; then
        build_cmd="go build ./..."
    elif [ -f "$GITHUB_WORKSPACE/package.json" ]; then
        build_cmd="npm run build --silent"
    elif [ -f "$GITHUB_WORKSPACE/Cargo.toml" ]; then
        build_cmd="cargo check"
    elif [ -f "$GITHUB_WORKSPACE/pyproject.toml" ]; then
        build_cmd="python -m compileall -q ."
    else
        build_cmd="true"
    fi

    local prompts_dir="$SPROUT_AGENT_PROMPTS"
    local run_dir="$SPROUT_RUN_DIR"
    jq -n \
        --arg provider "$AI_PROVIDER" \
        --arg model    "$AI_MODEL" \
        --arg initial_prompt "$SPROUT_RUN_DIR/prompt.md" \
        --arg implement "$prompts_dir/fix_implement_prompt.md" \
        --arg tests     "$prompts_dir/fix_tests_prompt.md" \
        --arg review    "$prompts_dir/fix_review_prompt.md" \
        --arg fix_loop  "$prompts_dir/fix_fix_prompt.md" \
        --arg review_json "$run_dir/review.json" \
        --arg build_cmd "$build_cmd" \
        --arg repo     "${GITHUB_REPOSITORY:-unknown}" \
        --arg target   "${FIX_TARGET:-issue}" \
        --arg number   "${FIX_NUMBER:-?}" \
        --argjson max  "$EFFECTIVE_MAX_ITERATIONS" \
        --argjson budget "$EFFECTIVE_MAX_BUDGET_USD" \
        --argjson overrides "$overrides" \
        '{
            description: ("Fix " + $target + " #" + $number + " in " + $repo),
            no_web_ui: true,
            persist_runtime_overrides: false,
            continue_on_error: true,
            budget: { usd: $budget, warn_at: [0.5, 0.8], on_exceed: "truncate" },
            initial: {
                prompt_file: $initial_prompt,
                provider: $provider,
                model: $model,
                persona: "orchestrator",
                skip_prompt: true,
                max_iterations: $max,
                subagent_overrides: $overrides,
                risk_profile: "permissive"
            },
            steps: [
                {
                    name: "implement",
                    when: "always",
                    persona: "coder",
                    max_iterations: 200,
                    subagent_overrides: $overrides,
                    risk_profile: "permissive",
                    prompt_file: $implement
                },
                {
                    name: "tests",
                    when: "on_success",
                    persona: "tester",
                    max_iterations: 120,
                    subagent_overrides: $overrides,
                    risk_profile: "permissive",
                    prompt_file: $tests
                },
                {
                    name: "review",
                    when: "on_success",
                    persona: "reviewer",
                    max_iterations: 100,
                    subagent_overrides: $overrides,
                    risk_profile: "cautious",
                    prompt_file: $review
                },
                {
                    name: "build",
                    when: "on_success",
                    command: $build_cmd,
                    risk_profile: "default"
                },
                {
                    name: "fix_review_findings",
                    when: "on_success",
                    file_exists: [$review_json],
                    persona: "orchestrator",
                    max_iterations: 80,
                    subagent_overrides: $overrides,
                    risk_profile: "permissive",
                    prompt_file: $fix_loop
                }
            ]
        }' > "$out"

    log_ok "Workflow JSON rendered to $out"
}

# fix_commit_and_pr — final commit + PR step for issue mode. Runs *after*
# the agent completes; carries out the cheap mechanical work the agent
# shouldn't burn tokens on.
fix_commit_and_pr() {
    local branch="$1"
    (
        cd "$GITHUB_WORKSPACE"

        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
        fi

        git add -A
        if [ -n "$(git status --porcelain)" ]; then
            local commit_msg
            commit_msg="sprout: implement issue #${ISSUE_NUMBER}

Auto-generated by sprout-agent. See PR description for details."
            git commit -m "$commit_msg" 2>&1 | head -5 || true
            local push_log="$SPROUT_RUN_DIR/git-push.log"
            git push origin "$branch" >> "$push_log" 2>&1
            local push_exit=$?
            [ "$push_exit" -eq 0 ] || log_warn "git push exit=$push_exit (see $push_log)"
        fi

        if ! sprout pr --skip-prompt \
            > "$SPROUT_RUN_DIR/pr.stdout" 2> "$SPROUT_RUN_DIR/pr.stderr"; then
            log_warn "sprout pr failed; trying gh fallback"
            ( command -v gh >/dev/null 2>&1 \
              && gh pr create --head "$branch" \
                              --title "sprout: implement issue #${ISSUE_NUMBER}" \
                              --body "Auto-generated by sprout-agent. See context.md for the issue." \
                 > "$SPROUT_RUN_DIR/pr.stdout" 2>&1 ) \
                 || log_warn "gh pr create also failed (check $SPROUT_RUN_DIR/pr.stderr)"
        fi

        local pr_url
        pr_url=$(grep -oE 'https://github\.com/[^ ]+' "$SPROUT_RUN_DIR/pr.stdout" 2>/dev/null | head -1 || true)
        local pr_number
        pr_number=$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' || true)

        if [ -n "$pr_url" ]; then
            jq -n --arg url "$pr_url" --argjson num "${pr_number:-null}" \
                '{url: $url, number: $num}' > "$SPROUT_RUN_DIR/pr.json"
            log_ok "PR created: $pr_url"
            curl --fail --show-error --silent --max-time 30 \
                -H "authorization: Bearer $GITHUB_TOKEN" \
                -H "accept: application/vnd.github+json" \
                -X POST \
                "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
                -d "$(jq -n --arg body "Draft PR opened: $pr_url" '{body: $body}')" \
                >/dev/null 2>&1 || true
        else
            log_warn "No PR URL detected — see $SPROUT_RUN_DIR/pr.{stdout,stderr}"
        fi

        git config --unset credential.helper 2>/dev/null || true
    )
}

# Execute main after all functions are defined — unless sourced by another
# script (e.g. plan.sh sources fix.sh for fix_fetch_context). The sourcing
# script sets SPROUT_SUPPRESS_MAIN=1 to prevent double execution.
if [ -z "${SPROUT_SUPPRESS_MAIN:-}" ]; then
    fix_main
fi
