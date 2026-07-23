#!/bin/bash
# configure-sprout.sh — write ~/.config/sprout/config.json and api_keys.json
# from the GitHub Action inputs.
#
# This is the place where every env var the user supplied becomes part of
# sprout's persisted config. We keep this single-purpose: produce a valid
# config.json + api_keys.json file. We do NOT run sprout here — that
# happens in dispatch.sh, per mode.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log_info "Writing sprout config to $SPROUT_CONFIG..."

mkdir -p "$SPROUT_CONFIG"

# ---------------------------------------------------------------------------
# api_keys.json — sprout reads these from env natively; we also persist
# them so the user can inspect/modify them after the run, and so the
# configuration is self-contained for debugging.
#
# We build the JSON via `jq` (not shell string concatenation) so a
# future input with embedded quote characters can't break the file.
# ---------------------------------------------------------------------------
log_info "Writing api_keys.json via jq..."

# Inputs whose values are non-empty are included; absent values are skipped.
# `$env` is jq's special object that reads process environment.
jq -n '
    {
        openai:     ($env.OPENAI_API_KEY     // empty | select(. != "")),
        openrouter: ($env.OPENROUTER_API_KEY // empty | select(. != "")),
        deepinfra:  ($env.DEEPINFRA_API_KEY  // empty | select(. != "")),
        zai:        ($env.ZAI_API_KEY        // empty | select(. != "")),
        chutes:     ($env.CHUTES_API_KEY     // empty | select(. != "")),
        mistral:    ($env.MISTRAL_API_KEY    // empty | select(. != "")),
        jinaai:     ($env.JINA_API_KEY       // empty | select(. != ""))
    }
    | with_entries(select(.value != null and .value != ""))
' > "$SPROUT_CONFIG/api_keys.json"

if [ "$(jq 'keys | length' "$SPROUT_CONFIG/api_keys.json")" -eq 0 ]; then
    log_warn "No provider API keys were set — every AI call will fail until you add one to the workflow's secrets."
fi

# ---------------------------------------------------------------------------
# config.json — minimal but enough for sprout to start with the right
# primary provider/model. Subagent overrides (coder/reviewer) live in the
# workflow JSON passed via --workflow-config, not here — keeps this file
# static and lets each mode override per-step without mutating it.
# ---------------------------------------------------------------------------
jq -n \
    --arg provider "$AI_PROVIDER" \
    --arg model    "$AI_MODEL" \
    '{
        version: "3.0",
        last_used_provider: $provider,
        provider_models: { ($provider): $model },
        provider_priority: [$provider]
    }' > "$SPROUT_CONFIG/config.json"

log_ok "Config written"
log_debug "primary: $AI_PROVIDER / $AI_MODEL"
log_debug "subagent overrides — coder: $CODER_PROVIDER/${CODER_MODEL:-<inherit>} reviewer: $REVIEWER_PROVIDER/${REVIEWER_MODEL:-<inherit>}"

# ---------------------------------------------------------------------------
# provider_priority.txt — sprout falls back through this list when its
# preferred provider fails. We build it dynamically from which *_API_KEY
# env vars the user actually set, in a sensible order. Reasoning:
#
#   1) OpenRouter is the broadest backup (every model behind one key).
#      It belongs first when set, so a partial setup still works.
#   2) The user-selected AI_PROVIDER should sit at index 0 explicitly
#      (sprout prefers it anyway, but listing it first reduces a cold-
#      call round trip if the first attempt fails).
#   3) We then sweep known providers in a stable default order. Any
#      provider without a key is skipped.
# ---------------------------------------------------------------------------
log_info "Building provider_priority.txt..."

PROVIDER_ORDER=(openrouter openai deepinfra chutes zai mistral jinaai)
PROVIDER_PRIORITY=()

# If the user set a primary, put it first (only if we have a key).
if [ -n "${AI_PROVIDER:-}" ]; then
    case "$AI_PROVIDER" in
        openai|openrouter|deepinfra|chutes|zai|mistral|jinaai)
            if [ -n "$(eval printf '%s' "\${${AI_PROVIDER^^}_API_KEY:-}")" ]; then
                PROVIDER_PRIORITY+=("$AI_PROVIDER")
            fi
            ;;
    esac
fi

# Then add the rest, skipping providers already chosen and skipping any
# provider with no configured key.
for p in "${PROVIDER_ORDER[@]}"; do
    if [[ " ${PROVIDER_PRIORITY[*]:-} " == *" $p "* ]]; then
        continue
    fi
    case "$p" in
        openai)     [ -n "${OPENAI_API_KEY:-}"     ] && PROVIDER_PRIORITY+=("$p") ;;
        openrouter) [ -n "${OPENROUTER_API_KEY:-}" ] && PROVIDER_PRIORITY+=("$p") ;;
        deepinfra)  [ -n "${DEEPINFRA_API_KEY:-}"  ] && PROVIDER_PRIORITY+=("$p") ;;
        chutes)     [ -n "${CHUTES_API_KEY:-}"     ] && PROVIDER_PRIORITY+=("$p") ;;
        zai)        [ -n "${ZAI_API_KEY:-}"        ] && PROVIDER_PRIORITY+=("$p") ;;
        mistral)    [ -n "${MISTRAL_API_KEY:-}"    ] && PROVIDER_PRIORITY+=("$p") ;;
        jinaai)     [ -n "${JINA_API_KEY:-}"       ] && PROVIDER_PRIORITY+=("$p") ;;
    esac
done

if [ "${#PROVIDER_PRIORITY[@]}" -eq 0 ]; then
    log_warn "No provider has a usable API key — provider_priority.txt will be empty"
    : > "$SPROUT_CONFIG/provider_priority.txt"
else
    printf '%s\n' "${PROVIDER_PRIORITY[@]}" > "$SPROUT_CONFIG/provider_priority.txt"
    log_ok "Provider priority: ${PROVIDER_PRIORITY[*]}"
fi
