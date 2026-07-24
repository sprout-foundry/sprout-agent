#!/bin/bash
# review_lib.sh — helpers shared by review.sh. Split out so review.sh
# stays linear and each function has a clear name and contract.
#
# Functions are intentionally defined after their use sites; shellcheck
# doesn't see the run-time order, so silence the cosmetic warning.
# shellcheck disable=SC2218
# PR_NUMBER is set by review.sh before sourcing this file; shellcheck
# can't see across files.
# shellcheck disable=SC2153
set -euo pipefail
source "$SPROUT_AGENT_SCRIPTS/common.sh"

# review_fetch_context — pull metadata, diff, comments for a PR and write
# to $SPROUT_RUN_DIR.
#
# Output files:
#   context.md   — human-readable summary the model reads
#   full.diff    — the unified diff
#   review.json  — written by the reviewer later; this function just ensures
#                  the file doesn't exist or is empty
#   summary.md   — written by the reviewer later
review_fetch_context() {
    local pr_number="$PR_NUMBER"
    local repo="$GITHUB_REPOSITORY"
    local token="$GITHUB_TOKEN"
    local out="$SPROUT_RUN_DIR"
    local hdr=()
    [ -n "$token" ] && hdr=(-H "authorization: Bearer $token")

    # Guard against an unset or malformed PR number. action.yml marks
    # `pr-number` required, but a non-numeric value (e.g. a typo) would
    # produce a malformed API URL and a confusing 404.
    if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
        log_err "PR_NUMBER is not a positive integer: '$pr_number' — check the action's `pr-number` input"
        return 1
    fi

    if [ -z "$repo" ] || [ "$repo" = "owner/" ] || [ "$repo" = "/repo" ]; then
        log_err "GITHUB_REPOSITORY is unset; this action only runs inside a GitHub-Actions-triggered workflow"
        return 1
    fi

    log_info "Fetching PR #${pr_number} metadata from $repo..."
    local meta
    if ! meta=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr_number}"); then
        log_err "Failed to fetch PR metadata — token may lack pull:read scope"
        return 1
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

    # Unified diff. Prefer git on-disk (cheap, paginated by context lines)
    # over the API .diff endpoint which counts in API quota. We fall back
    # to the API endpoint if the local repo doesn't have both refs.
    local diff_file="$out/full.diff"
    if [ -d "$GITHUB_WORKSPACE/.git" ] && \
       git -C "$GITHUB_WORKSPACE" rev-parse --verify --quiet "$sha" >/dev/null 2>&1; then
        log_info "Computing diff via git (cheap path)..."
        if ! git -C "$GITHUB_WORKSPACE" diff --unified=3 "${base}...${sha}" > "$diff_file" 2>/dev/null; then
            log_warn "git diff failed; falling back to API .diff"
            curl --fail --show-error --silent --max-time 60 \
                -H "accept: application/vnd.github.v3.diff" \
                "${hdr[@]}" \
                "https://api.github.com/repos/${repo}/pulls/${pr_number}.diff" > "$diff_file"
        fi
    else
        log_info "Computing diff via GitHub API (.diff endpoint)..."
        curl --fail --show-error --silent --max-time 60 \
            -H "accept: application/vnd.github.v3.diff" \
            "${hdr[@]}" \
            "https://api.github.com/repos/${repo}/pulls/${pr_number}.diff" > "$diff_file"
    fi

    local diff_lines
    diff_lines=$(wc -l < "$diff_file" 2>/dev/null || echo 0)
    log_info "Diff: $diff_lines lines"

    # Issue-style comments (general PR chatter, not inline review comments).
    log_info "Fetching issue comments..."
    local comments
    comments=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/issues/${pr_number}/comments?per_page=100&paginate=true" || echo "[]")

    # Inline review comments (the ones posted as "File X, Line Y").
    log_info "Fetching inline review comments..."
    local review_comments
    review_comments=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr_number}/comments?per_page=100&paginate=true" || echo "[]")

    # Existing review verdicts (APPROVED / CHANGES_REQUESTED / COMMENTED).
    log_info "Fetching PR reviews..."
    local reviews
    reviews=$(curl --fail --show-error --silent --max-time 30 \
        "${hdr[@]}" \
        "https://api.github.com/repos/${repo}/pulls/${pr_number}/reviews?per_page=100&paginate=true" || echo "[]")

    # Linked issues — close keywords + #NNN refs in PR body/title.
    log_info "Fetching linked issues..."
    local linked_issues="[]"
    local refs
    refs=$(printf '%s' "$body $title" | grep -oE '#[0-9]+' | sort -u | tr -d '#' || true)
    if [ -n "$refs" ]; then
        local issues_buf="[]"
        for n in $refs; do
            local issue_meta
            if ! issue_meta=$(curl --fail --show-error --silent --max-time 15 \
                "${hdr[@]}" \
                "https://api.github.com/repos/${repo}/issues/${n}" 2>/dev/null); then
                log_debug "linked issue #$n not fetchable (likely 404/403); skipping"
                continue
            fi
            local issue_title issue_body
            issue_title=$(printf '%s' "$issue_meta" | jq -r '.title // ""')
            issue_body=$(printf '%s' "$issue_meta" | jq -r '.body // ""' | head -c 2000)
            if [ -n "$issue_title" ]; then
                issues_buf=$(printf '%s' "$issues_buf" | jq \
                    --arg n "$n" \
                    --arg t "$issue_title" \
                    --arg b "$issue_body" \
                    '. + [{number: ($n|tonumber), title: $t, body: $b}]')
            fi
        done
        linked_issues="$issues_buf"
    fi

    # Render context.md — what the reviewer prompt points at.
    {
        printf '# PR Review Context\n\n'
        printf '**PR**: %s\n' "$url"
        printf '**Title**: %s\n' "$title"
        printf '**Author**: @%s\n' "$author"
        printf '**Base**: %s\n' "$base"
        printf '**State**: %s\n\n' "$state"
        printf '## Description\n\n%s\n\n' "$body"
        printf '## Existing PR Comments (%s)\n\n' \
            "$(printf '%s' "$comments" | jq 'length')"
        printf '%s\n\n' "$(printf '%s' "$comments" | jq -r '.[] | "**@\(.user.login)** (\(.created_at)):\n\(.body)\n---\n"' || true)"
        printf '## Existing Reviews (%s)\n\n' \
            "$(printf '%s' "$reviews" | jq 'length')"
        printf '%s\n\n' "$(printf '%s' "$reviews" | jq -r '.[] | "**@\(.user.login)** (\(.state)):\n\(.body // "(no body)")\n---\n"' || true)"
        printf '## Inline Review Comments Already on PR (%s)\n\n' \
            "$(printf '%s' "$review_comments" | jq 'length')"
        printf '%s\n\n' "$(printf '%s' "$review_comments" | jq -r '.[] | "**@\(.user.login)** on `\(.path):\(.line // .original_line)`:\n\(.body)\n---\n"' || true)"
        printf '## Linked Issues (%s)\n\n' "$(printf '%s' "$linked_issues" | jq 'length')"
        printf '%s\n\n' "$(printf '%s' "$linked_issues" | jq -r '.[] | "### #\(.number): \(.title)\n\(.body)\n---\n"' || true)"
        printf '## Diff\n\nThe unified diff is at full.diff (%s lines).\n' "$diff_lines"
    } > "$out/context.md"

    # Render prompt.md — what the model actually receives.
    #
    # We substitute REVIEW_TYPE and COMMENT_THRESHOLD into the prompt so
    # the reviewer sees them inline as part of its instructions, not as
    # ambient env vars. Inline text is more reliable than env-var lookups
    # inside an LLM. The prompt template's placeholders are
    # ${REVIEW_TYPE_PARAGRAPH} and ${COMMENT_THRESHOLD_PARAGRAPH}; both
    # are filled with a one-paragraph guidance block.
    local rt="${REVIEW_TYPE:-comprehensive}"
    case "$rt" in
        comprehensive|security|performance) ;;
        *) log_warn "Unknown REVIEW_TYPE='$rt'; falling back to 'comprehensive'"; rt="comprehensive" ;;
    esac
    local ct="${COMMENT_THRESHOLD:-medium}"
    case "$ct" in
        high|medium|low) ;;
        *) log_warn "Unknown COMMENT_THRESHOLD='$ct'; falling back to 'medium'"; ct="medium" ;;
    esac
    local rt_para ct_para
    case "$rt" in
        security)
            rt_para="**Review focus: security.** Prioritise vulnerabilities (auth/authz bypasses, injection, secrets, SSRF, deserialization, dependency CVEs, supply-chain risks). Other categories are out of scope for this review."
            ;;
        performance)
            rt_para="**Review focus: performance.** Prioritise regressions (algorithmic complexity, allocations, locking, query plans, network round-trips, unbounded loops). Other categories are out of scope for this review."
            ;;
        *)
            rt_para="**Review focus: comprehensive.** Cover all categories (correctness, security, performance, maintainability) weighted by severity."
            ;;
    esac
    case "$ct" in
        high)
            ct_para="**Comment threshold: high.** Post inline comments ONLY for critical issues (production crashes, data loss, immediately exploitable security vulnerabilities). Otherwise post the summary as a single PR comment."
            ;;
        medium)
            ct_para="**Comment threshold: medium.** Post inline comments for critical AND major issues (real bugs, security vulnerabilities, significant performance regressions, logic errors)."
            ;;
        *)
            ct_para="**Comment threshold: low.** Post inline comments for critical, major, AND minor issues (including code-quality concerns that need fixing)."
            ;;
    esac

    # sed substitution. We anchor with %%...%% markers so they don't collide
    # with prose in the prompt that happens to use ${...} syntax. Using |
    # as the sed delimiter keeps slashes in prose untouched.
    local prompt_body
    prompt_body=$(cat "$SPROUT_AGENT_PROMPTS/review_initial_prompt.md")
    prompt_body=$(printf '%s' "$prompt_body" | sed \
        -e "s|%%REVIEW_TYPE_PARAGRAPH%%|$rt_para|g" \
        -e "s|%%COMMENT_THRESHOLD_PARAGRAPH%%|$ct_para|g")
    {
        printf '%s' "$prompt_body"
        printf '\n\n## Context\n\n'
        cat "$out/context.md"
    } > "$out/prompt.md"

    log_ok "Context ready ($(wc -c < "$out/context.md") bytes; diff: $diff_lines lines; review_type=$rt; threshold=$ct)"
}

# review_render_workflow_json — write $1 as the AgentWorkflowConfig for review.
#
# Wires subagent overrides for the reviewer persona. The reviewer persona
# itself is the main step in the workflow; the orchestrator only loads it
# to set up classification. Subagent overrides matter most here because the
# reviewer IS the agent for this run — coder/reviewer overrides apply when
# reviewer spawns further reviewers (we don't currently fan-out, but the
# fields are reserved for future parallelism).
review_render_workflow_json() {
    local out="$1"

    # Build subagent_overrides map. Skip empty entries so absent model
    # fields fall through to the primary.
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

    jq -n \
        --arg provider "$AI_PROVIDER" \
        --arg model    "$AI_MODEL" \
        --argjson max  "$EFFECTIVE_MAX_ITERATIONS" \
        --argjson budget "$EFFECTIVE_MAX_BUDGET_USD" \
        --argjson overrides "$overrides" \
        --arg prompt_file "$SPROUT_RUN_DIR/prompt.md" \
        '{
            description: "PR review for \(env.GITHUB_REPOSITORY) PR #\(env.PR_NUMBER or \"?\")",
            no_web_ui: true,
            persist_runtime_overrides: false,
            continue_on_error: true,
            budget: { usd: $budget, warn_at: [0.5, 0.8], on_exceed: "truncate" },
            initial: {
                prompt_file: $prompt_file,
                provider: $provider,
                model: $model,
                persona: "reviewer",
                skip_prompt: true,
                max_iterations: $max,
                subagent_overrides: $overrides,
                risk_profile: "cautious"
            }
        }' > "$out"

    log_ok "Workflow JSON rendered to $out"
}

# review_post_results — POST review.json + summary.md to the PR.
#
# 1. Always POST a single summary comment with review_action.
# 2. If there are inline comments, attempt a full review submission via
#    the /reviews endpoint (one round trip). If that fails (e.g. the bot
#    owns the PR), fall back to posting individual inline comments via
#    /pulls/{n}/comments.
# 3. Uploads review.json + summary.md as workflow artifacts via the
#    runlog — caller does that via GH Actions' upload-artifact step, not
#    here.
review_post_results() {
    local pr_number="$1"
    local review_json="$2"
    # summary_md is accepted for symmetry with the other modes but is
    # intentionally not used here — the human-readable summary lives in
    # review.json.summary which we post in-line below.
    local _summary_md_unused="$3"  # see comment above
    local repo="$GITHUB_REPOSITORY"
    local token="$GITHUB_TOKEN"
    local hdr=(-H "authorization: Bearer $token" -H "accept: application/vnd.github+json")

    if ! jq -e . "$review_json" >/dev/null 2>&1; then
        log_err "review.json is invalid; skipping post"
        return 1
    fi

    local summary approval comments_json
    summary=$(jq -r '.summary // "Review complete."' "$review_json")
    approval=$(jq -r '.approval_status // "comment"' "$review_json")
    comments_json=$(jq -c '.comments // []' "$review_json")

    # Threshold filter. Driven by COMMENT_THRESHOLD env var (default
    # medium). Inline comments below the floor are dropped — the model's
    # prompt already biases its writing toward the threshold, but we
    # filter again at post time so a model that mis-calibrates still
    # respects the user's stated noise tolerance.
    local threshold="${COMMENT_THRESHOLD:-medium}"
    case "$threshold" in
        high|medium|low) ;;
        *) log_warn "Unknown COMMENT_THRESHOLD='$threshold'; falling back to 'medium'"; threshold="medium" ;;
    esac
    local allowed_severities
    case "$threshold" in
        high)   allowed_severities='["critical"]' ;;
        medium) allowed_severities='["critical","major"]' ;;
        *)      allowed_severities='["critical","major","minor","suggestion"]' ;;
    esac
    local filtered_count total_count
    total_count=$(printf '%s' "$comments_json" | jq 'length')
    comments_json=$(printf '%s' "$comments_json" | jq --argjson s "$allowed_severities" \
        '[.[] | select((.severity // "major") as $sev | $s | index($sev) != null)]')
    filtered_count=$(printf '%s' "$comments_json" | jq 'length')
    if [ "$filtered_count" -lt "$total_count" ]; then
        log_info "Threshold=$threshold: kept $filtered_count/$total_count inline comments"
    fi

    # Map our approval semantics to GitHub's review event API. Unknown
    # statuses default to COMMENT — we log a warning so the user can
    # see we got an unexpected value rather than silently downgrading.
    local event
    case "$approval" in
        approve)         event="APPROVE" ;;
        request_changes) event="REQUEST_CHANGES" ;;
        comment|*)       event="COMMENT"
            if [ "$approval" != "comment" ]; then
                log_warn "Unknown approval_status='$approval'; posting as COMMENT"
            fi
            ;;
    esac

    # Self-PR guard. GitHub forbids approving/requesting-changes on your
    # own PR — the API returns 422 with message "Can not approve your own
    # pull request" or "Can not request changes on your own pull request".
    # We proactively downgrade APPROVE/REQUEST_CHANGES → COMMENT on a
    # self-authored PR so the user doesn't get a confusing 422 in the
    # action logs.
    #
    # We resolve the bot's login via the token's /user endpoint. On
    # classic GitHub Actions this is "github-actions[bot]"; for users
    # supplying a personal access token it's their own login. The PR
    # author comes from the context file written by review_fetch_context
    # (cheap because that file is already on disk).
    local bot_login pr_author=""
    bot_login=$(curl --fail --show-error --silent --max-time 10 \
        "${hdr[@]}" "https://api.github.com/user" 2>/dev/null \
        | jq -r '.login // empty' 2>/dev/null) || bot_login=""
    if [ -f "$SPROUT_RUN_DIR/context.md" ]; then
        pr_author=$(awk -F': ' '/^\*\*Author\*\*: @/ {print $2; exit}' \
            "$SPROUT_RUN_DIR/context.md" | tr -d '@' || true)
    fi

    if [ -n "$bot_login" ] && [ -n "$pr_author" ] \
        && [ "$bot_login" = "$pr_author" ]; then
        if [ "$event" = "APPROVE" ] || [ "$event" = "REQUEST_CHANGES" ]; then
            log_warn "Self-PR detected (bot=$bot_login, author=$pr_author); downgrading $event → COMMENT"
            event="COMMENT"
        fi
    fi

    log_info "Posting review to PR #$pr_number (event=$event, comments=$filtered_count)"

    # Single POST: GitHub's /reviews endpoint accepts the body, verdict,
    # and inline comments in one atomic request. Avoids duplicating the
    # summary as a separate issue comment (which would show up twice in
    # the PR timeline).
    local payload
    payload=$(jq -n \
        --arg body "$summary" \
        --arg event "$event" \
        --argjson comments "$comments_json" \
        '{
            body: $body,
            event: $event,
            comments: ($comments | map({
                path: .file,
                line: .line,
                side: (.side // "RIGHT"),
                body: .body
            }))
        }')

    local resp status
    resp=$(curl --silent --max-time 60 \
        "${hdr[@]}" -X POST \
        "https://api.github.com/repos/${repo}/pulls/${pr_number}/reviews" \
        -d "$payload" \
        -w '\n%{http_code}')
    status=$(printf '%s' "$resp" | tail -1)
    # Capture the body for future error inspection. Kept available for log
    # debugging via DEBUG=1.
    [ "${DEBUG:-false}" = "true" ] && log_debug "review POST body: $(printf '%s' "$resp" | sed '$d')"

    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
        log_ok "Review posted as PR review (event=$event)"
        return 0
    fi

    # Common failure: bot owns the PR and is trying to REQUEST_CHANGES on
    # its own PR. Per GitHub rules, that becomes COMMENT.
    if [ "$event" = "REQUEST_CHANGES" ]; then
        log_warn "POST failed ($status); retrying as COMMENT (likely self-authored PR)"
        payload=$(printf '%s' "$payload" | jq '.event = "COMMENT"')
        resp=$(curl --silent --max-time 60 \
            "${hdr[@]}" -X POST \
            "https://api.github.com/repos/${repo}/pulls/${pr_number}/reviews" \
            -d "$payload" \
            -w '\n%{http_code}')
        status=$(printf '%s' "$resp" | tail -1)
        if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
            log_ok "Review posted as COMMENT (downgraded from REQUEST_CHANGES)"
            return 0
        fi
    fi

    # Last resort: post each comment individually. This produces visible
    # inline comments even when the review-event POST fails for unrelated
    # reasons.
    log_warn "Review POST failed ($status); falling back to per-comment POSTs"
    while read -r c; do
        [ -z "$c" ] && continue
        curl --fail --show-error --silent --max-time 30 \
            "${hdr[@]}" -X POST \
            "https://api.github.com/repos/${repo}/pulls/${pr_number}/comments" \
            -d "$c" >/dev/null \
            || log_warn "  Failed to post comment on $(printf '%s' "$c" | jq -r .path):$(printf '%s' "$c" | jq -r .line)"
    done < <(printf '%s' "$comments_json" | jq -c '.[] | {path: .file, line: .line, side: (.side // "RIGHT"), body: .body}')

    log_ok "Fallback comment POST loop complete"
}

# check_missing_diff_files — checks whether files added by `git diff` in
# $1 are present on disk in $GITHUB_WORKSPACE. The user-facing warning
# helps users who forgot to checkout the PR head ref.
check_missing_diff_files() {
    local diff="$1"
    [ -f "$diff" ] || return 1

    local missing=0
    # Extract "+++ b/path/to/file" lines, skip /dev/null (deletions).
    while IFS= read -r line; do
        local path
        path=$(printf '%s' "$line" | sed -E 's|^\+\+\+ b/||')
        [ -z "$path" ] || [ "$path" = "/dev/null" ] && continue
        if [ ! -e "$GITHUB_WORKSPACE/$path" ]; then
            log_warn "Missing on disk: $path (did you forget ref: \${{ github.event.pull_request.head.ref }} ?)"
            missing=$((missing + 1))
        fi
    done < <(grep -E '^\+\+\+ ' "$diff" | grep -v '^+++ /dev/null' || true)

    [ "$missing" -gt 0 ]
}
