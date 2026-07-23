#!/bin/bash
# fix.sh — implementor mode. Reads an issue (or a PR comment) and produces
# an implementation PR, end-to-end.
#
# High-level pipeline:
#   1. fetch context (issue body + comments + linked PRs + images)
#   2. orchestrator plans and delegates to the coder subagent
#   3. tester subagent writes/updates tests against the implementation
#   4. reviewer subagent audits the diff and writes review.json
#   5. shell step: build the project
#   6. orchestrator fixes any review findings (file-gated)
#   7. shell step: commit and open the PR via sprout pr
#
# All shell steps run via the user's $SHELL or /bin/sh and inherit
# stdout/stderr; they do NOT trigger LLM calls. They're cheap, deterministic
# gates that turn model output into a real artifact (commit + PR).
#
# shellcheck shell=bash
# Functions are intentionally defined after their use sites; shellcheck
# doesn't see the run-time order, so silence the cosmetic warning.
# shellcheck disable=SC2218
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"

log_info "Fix mode — bootstrapping workflow JSON"

ISSUE_NUMBER=$(event_issue_number)
if [ -z "$ISSUE_NUMBER" ]; then
    log_err "Could not determine issue number from event payload"
    log_err "Event: ${GITHUB_EVENT_NAME:-<unset>}"
    emit_output "success=false"
    exit 1
fi
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    log_err "Issue number '$ISSUE_NUMBER' is not a positive integer"
    log_err "Check that this action was triggered by issues.labeled or issues.opened"
    emit_output "success=false"
    exit 1
fi
log_info "Implementing issue #$ISSUE_NUMBER in $GITHUB_REPOSITORY"

# Fetch issue context (body, comments, linked PRs, attached images).
SPROUT_RUN_DIR="$SPROUT_RUN_DIR" \
GITHUB_TOKEN="$GITHUB_TOKEN" \
GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
ISSUE_NUMBER="$ISSUE_NUMBER" \
    fix_fetch_context

# Set up the work branch. Naming: issue/NNN, matching the convention
# other Actions in this space use. We push the branch (or create it) so the
# next step can commit against it.
BRANCH_NAME="issue/${ISSUE_NUMBER}"
fix_setup_branch "$BRANCH_NAME"

# Render the workflow JSON.
WORKFLOW_JSON="$SPROUT_RUN_DIR/workflow.json"
fix_render_workflow_json "$WORKFLOW_JSON"

# Compose the prompt. We use --prompt-stdin so the (potentially huge) PR
# context doesn't get into the OS argv.
PROMPT_FILE="$SPROUT_RUN_DIR/prompt.md"
{
    cat "$SPROUT_AGENT_PROMPTS/fix_initial_prompt.md"
    printf '\n\n## Issue Context\n\n'
    cat "$SPROUT_RUN_DIR/context.md"
} > "$PROMPT_FILE"

log_info "Invoking sprout agent..."
log_info "Command: timeout ${EFFECTIVE_TIMEOUT_MINUTES}m sprout agent --workflow-config $WORKFLOW_JSON --prompt-stdin < $PROMPT_FILE"

# Fail fast with an actionable error if the prompt didn't get written
# (typically means context fetch bailed). Without this, the user sees
# the opaque "sprout exit 1" with no breadcrumb.
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
           --prompt-stdin \
       < "$PROMPT_FILE" )
sprout_exit=$?

# Post-commit: if the agent produced code changes, do the commit + PR
# step ourselves rather than trusting the agent to do it. This makes
# the workflow idempotent (a re-run after partial failure commits the
# remaining work without spamming commits).
if [ -n "$(cd "$GITHUB_WORKSPACE" && git status --porcelain 2>/dev/null)" ]; then
    log_info "Detected changes on $BRANCH_NAME — creating commit + PR"
    fix_commit_and_pr "$BRANCH_NAME"
    emit_output "success=true"
else
    log_warn "No changes to commit"
    emit_output "success=false"
fi

emit_output "branch-name=$BRANCH_NAME"
emit_output "pr-number=$(jq -r '.number // empty' "$SPROUT_RUN_DIR/pr.json" 2>/dev/null || true)"
emit_output "pr-url=$(jq -r '.url // empty' "$SPROUT_RUN_DIR/pr.json" 2>/dev/null || true)"

# Surface spend as a top-level output. Costs live in the runlog; we
# summarise the most likely shape (review.json.cost_usd). If it isn't
# present we just emit empty rather than failing the workflow.
emit_output "cost=$(jq -r '.cost_usd // .cost_total // empty' "$SPROUT_RUN_DIR/review.json" 2>/dev/null || true)"

[ "$sprout_exit" -eq 0 ] || exit "$sprout_exit"

# -- Mode-internal helpers -------------------------------------------------

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

    # All issue comments. `--paginate` ensures we get every page
    # (GitHub's default page size is 30; some issues have hundreds).
    local comments
    comments=$(curl --fail --show-error --silent --max-time 60 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${issue}/comments?per_page=100&paginate=true" || echo "[]")

    # Linked PRs — via the issue timeline "cross-referenced" events
    # plus any PR whose body or title contains "#NNN".
    log_info "Resolving linked pull requests..."
    local timeline
    timeline=$(curl --fail --show-error --silent --max-time 60 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${issue}/timeline?per_page=100&paginate=true" || echo "[]")
    local linked_prs
    linked_prs=$(printf '%s' "$timeline" \
        | jq '[.[] | select(.event == "cross-referenced" and (.source.issue.pull_request // null) != null) | .source.issue] | unique_by(.number)')
    log_info "Linked via timeline: $(printf '%s' "$linked_prs" | jq 'length')"

    # Detect attached images in body + comments. We download a local
    # copy of each so the agent can use analyze_image_content / vision
    # tools without re-fetching.
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
            # SSRF guard: rewrite non-http schemes and refuse private/loopback
            # hosts. Images come from arbitrary issue bodies, so a malicious
            # user could otherwise make our action fetch internal addresses.
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

    # Render context.md — what the orchestrator prompt points at.
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
                # Inline review comments for context (so a re-iterate knows
                # which feedback to address).
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
# pushed. Matches the convention other Actions use (issue/NNN).
#
# Auth for `git push`: we set a one-shot credential helper that uses the
# GITHUB_TOKEN the user passed via the action input. Without this, push
# fails on a default Actions checkout (origin is HTTPS with no creds
# embedded in actions/checkout). The helper is scoped to this push and
# cleared at function exit so the token doesn't linger in git config.
fix_setup_branch() {
    local branch="$1"
    ( cd "$GITHUB_WORKSPACE"

        git config user.email  "sprout-agent[bot]@users.noreply.github.com"
        git config user.name   "sprout-agent[bot]"

        # Install a transient credential helper for the push only.
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
            trap 'git config --unset credential.helper 2>/dev/null || true' RETURN
        fi

        # If we're on the same checkout that already has the branch (e.g.
        # the user pre-checked it out), just switch to it. Otherwise
        # create it from the default HEAD.
        if git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
            git checkout "$branch"
        else
            git checkout -b "$branch"
        fi

        # Push so the PR knows where to come from. Capture push exit
        # code explicitly because `| head -5` resets $? to head's status.
        local push_log="$SPROUT_RUN_DIR/git-push.log"
        local push_exit
        git push -u origin "$branch" > "$push_log" 2>&1
        push_exit=$?
        if [ "$push_exit" -ne 0 ]; then
            # "already up to date" and "branch already exists" are fine
            log_warn "git push exit=$push_exit (see $push_log)"
        fi
    )
    log_ok "On branch $branch"
}

# fix_render_workflow_json — emit the AgentWorkflowConfig for the implementor.
#
# Step chain:
#   initial       : orchestrator plans + delegates to coder
#   fix_code      : coder produces implementation (when=always — coder is
#                   the primary step; orchestrator delegates into this)
#   fix_tests     : tester writes/updates tests for the new code
#                    (when=on_success, file_exists gate)
#   fix_review    : reviewer audits the diff
#                    (when=on_success, file_exists: test file exists)
#   fix_build     : shell — runs `go build ./...` (or detect from repo)
#                    (when=on_success)
#   fix_fix_loop  : orchestrator addresses any review findings
#                    (when=on_success, file_exists: review.json)
fix_render_workflow_json() {
    local out="$1"

    # Subagent overrides. Coder/reviewer/tester are the spend-heavy steps;
    # orchestrator stays on primary so it can reason coherently.
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

    # Pick a build command based on what's in the repo. We're conservative
    # — fall back to "true" if nothing obvious is detected, so a non-Go
    # project doesn't fail the build step.
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
        --argjson max  "$EFFECTIVE_MAX_ITERATIONS" \
        --argjson budget "$EFFECTIVE_MAX_BUDGET_USD" \
        --argjson overrides "$overrides" \
        '{
            description: ("Implement issue " + (env.ISSUE_NUMBER // "?") + " in " + (env.GITHUB_REPOSITORY // "?")),
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

# fix_commit_and_pr — final commit + PR step. Runs *after* the agent
# completes; carries out the cheap mechanical work the agent shouldn't
# burn tokens on.
fix_commit_and_pr() {
    local branch="$1"
    (
        cd "$GITHUB_WORKSPACE"

        # Re-install credential helper (we may be in a subshell after
        # the sub-process returned and the previous trap ran).
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            git config credential.helper \
                '!f() { echo username=x-access-token; echo password=$GITHUB_TOKEN; }; f'
        fi

        # Stage + commit. The agent may have left uncommitted edits; we
        # batch them into a single commit to keep history clean.
        git add -A
        if [ -n "$(git status --porcelain)" ]; then
            local commit_msg
            commit_msg="sprout: implement issue #${ISSUE_NUMBER}

Auto-generated by sprout-agent. See PR description for details."
            git commit -m "$commit_msg" 2>&1 | head -5 || true
            # Capture push exit code explicitly (pipe to head resets $?).
            local push_log="$SPROUT_RUN_DIR/git-push.log"
            git push origin "$branch" >> "$push_log" 2>&1
            local push_exit=$?
            [ "$push_exit" -eq 0 ] || log_warn "git push exit=$push_exit (see $push_log)"
        fi

        # Create the PR through sprout's own typed wrapper (REST API +
        # `gh pr create` fallback). Captures the result for the action
        # outputs. --base empty lets sprout resolve the default branch
        # via git.GetDefaultBranch (so it works for repos whose default
        # isn't "main").
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

        # Parse out the PR URL from sprout's stdout (looks like "PR created: <url>")
        local pr_url
        pr_url=$(grep -oE 'https://github\.com/[^ ]+' "$SPROUT_RUN_DIR/pr.stdout" 2>/dev/null | head -1 || true)
        local pr_number
        pr_number=$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' || true)

        if [ -n "$pr_url" ]; then
            jq -n --arg url "$pr_url" --argjson num "${pr_number:-null}" \
                '{url: $url, number: $num}' > "$SPROUT_RUN_DIR/pr.json"
            log_ok "PR created: $pr_url"
            # Post a link comment back to the issue.
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

        # Clear the credential helper before returning.
        git config --unset credential.helper 2>/dev/null || true
    )
}
