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
# We pass each env var explicitly via --arg because the $env shortcut in
# jq requires jq 1.7+, but GitHub Actions runners ship with jq 1.6
# (apt-get install jq on Ubuntu 22.04 / 24.04). Passing through --arg is
# portable across all supported jq versions.
#
# Why a single with_entries filter rather than per-field select: putting
# `select(. != "")` inside an object expression like `{a: ($x | select(. != ""))}`
# drops the entire key-value pair (the select emits an empty stream,
# which jq treats as "no value" at the object-field level). So we build
# the full object with empty strings and let with_entries drop the
# empties in one pass.
jq -n \
    --arg openai     "${OPENAI_API_KEY:-}"     \
    --arg openrouter "${OPENROUTER_API_KEY:-}" \
    --arg deepinfra  "${DEEPINFRA_API_KEY:-}"  \
    --arg zai        "${ZAI_API_KEY:-}"        \
    --arg zaicoding  "${ZAI_CODING_API_KEY:-}"  \
    --arg chutes     "${CHUTES_API_KEY:-}"     \
    --arg mistral    "${MISTRAL_API_KEY:-}"    \
    --arg jinaai     "${JINA_API_KEY:-}"       \
    --arg custom     "${CUSTOM_PROVIDER_API_KEY:-}" \
    --arg custom_name "${CUSTOM_PROVIDER_NAME:-}" \
    '{
        openai:     $openai,
        openrouter: $openrouter,
        deepinfra:  $deepinfra,
        zai:        $zai,
        "zai-coding": $zaicoding,
        chutes:     $chutes,
        mistral:    $mistral,
        jinaai:     $jinaai
    }
    | (if ($custom != "" and $custom_name != "") then
          . + { ($custom_name): $custom }
      else . end)
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
        version: "2.0",
        last_used_provider: $provider,
        provider_models: { ($provider): $model },
        provider_priority: [$provider]
    }' > "$SPROUT_CONFIG/config.json"

# ---------------------------------------------------------------------------
# Custom provider — register an OpenAI-compatible endpoint not in the
# built-in list (Groq, Together, Fireworks, vLLM, corporate proxies,
# LM Studio, etc.). Triggered by setting CUSTOM_PROVIDER_URL. The name
# defaults to "custom"; the user can pick any identifier that doesn't
# collide with the built-in providers (openai, openrouter, ...).
#
# Why jq-only and not string concat: a model name or endpoint with
# special characters must not corrupt the config file. Same F6 lesson
# as api_keys.json above.
# ---------------------------------------------------------------------------
if [ -n "${CUSTOM_PROVIDER_URL:-}" ] && [ -n "${CUSTOM_PROVIDER_NAME:-}" ]; then
    log_info "Registering custom provider '${CUSTOM_PROVIDER_NAME}' → ${CUSTOM_PROVIDER_URL}"
    custom_model="${CUSTOM_PROVIDER_MODEL:-$AI_MODEL}"
    requires_key="false"
    [ -n "${CUSTOM_PROVIDER_API_KEY:-}" ] && requires_key="true"

    # In-memory registration via custom_providers on the root config. The
    # spawn up on next Save(), so this is enough for the current run but
    # the canonical store is the per-provider file below.
    jq --arg name "$CUSTOM_PROVIDER_NAME" \
       --arg url  "$CUSTOM_PROVIDER_URL" \
       --arg mdl  "$custom_model" \
       --argjson req "$requires_key" \
       '.custom_providers[$name] = {
            name:             $name,
            endpoint:         $url,
            model_name:       $mdl,
            requires_api_key: $req,
            env_var:          "CUSTOM_PROVIDER_API_KEY"
        }' "$SPROUT_CONFIG/config.json" > "$SPROUT_CONFIG/config.json.tmp" \
        && mv "$SPROUT_CONFIG/config.json.tmp" "$SPROUT_CONFIG/config.json"

    # Canonical store: per-provider JSON in providers/${name}.json. This is
    # what sprout's CustomProviderRegistry / LoadConfigWithLayers actually
    # reads on subsequent runs, and what survives a config.json Save().
    # We write it directly rather than calling `sprout custom add` so this
    # script doesn't depend on sprout being installed yet (this runs in
    # the Configure step, before Install sprout).
    mkdir -p "$SPROUT_CONFIG/providers"
    jq -n \
        --arg name "$CUSTOM_PROVIDER_NAME" \
        --arg url  "$CUSTOM_PROVIDER_URL" \
        --arg mdl  "$custom_model" \
        --argjson req "$requires_key" \
        '{
            name:             $name,
            endpoint:         $url,
            model_name:       $mdl,
            requires_api_key: $req,
            env_var:          "CUSTOM_PROVIDER_API_KEY",
            auth_type:        "bearer",
            context_size:     32768,
            timeout_seconds:  120
        }' > "$SPROUT_CONFIG/providers/${CUSTOM_PROVIDER_NAME}.json"

    log_ok "Custom provider ${CUSTOM_PROVIDER_NAME} registered"
elif [ -n "${CUSTOM_PROVIDER_URL:-}" ] || [ -n "${CUSTOM_PROVIDER_NAME:-}" ]; then
    log_warn "CUSTOM_PROVIDER_URL and CUSTOM_PROVIDER_NAME must both be set to register a custom provider — ignoring"
fi

log_ok "Config written"
log_debug "primary: ${AI_PROVIDER:-<unset>} / ${AI_MODEL:-<unset>}"
log_debug "subagent overrides — coder: ${CODER_PROVIDER:-<unset>}/${CODER_MODEL:-<inherit>} reviewer: ${REVIEWER_PROVIDER:-<unset>}/${REVIEWER_MODEL:-<inherit>}"

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

PROVIDER_ORDER=(openrouter openai deepinfra chutes zai zai-coding mistral jinaai)
PROVIDER_PRIORITY=()

# If the user set a primary, put it first (only if we have a key).
# Built-in providers (openai/openrouter/...) require their *_API_KEY;
# custom providers use CUSTOM_PROVIDER_API_KEY.
if [ -n "${AI_PROVIDER:-}" ]; then
    case "$AI_PROVIDER" in
        zai-coding)
            if [ -n "${ZAI_CODING_API_KEY:-}" ]; then
                PROVIDER_PRIORITY+=("$AI_PROVIDER")
            fi
            ;;
        openai|openrouter|deepinfra|chutes|zai|mistral|jinaai)
            if [ -n "$(eval printf '%s' "\${${AI_PROVIDER^^}_API_KEY:-}")" ]; then
                PROVIDER_PRIORITY+=("$AI_PROVIDER")
            fi
            ;;
        *)
            # Custom provider name — register if a key was provided.
            if [ -n "${CUSTOM_PROVIDER_API_KEY:-}" ] && [ "$AI_PROVIDER" = "${CUSTOM_PROVIDER_NAME:-}" ]; then
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
        zai-coding) [ -n "${ZAI_CODING_API_KEY:-}" ] && PROVIDER_PRIORITY+=("$p") ;;
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
