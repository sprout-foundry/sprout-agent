# sprout-agent

GitHub Action that runs [sprout](https://github.com/sprout-foundry/sprout) to review PRs, fix issues, or generate implementation plans.

## Quick start

```yaml
name: sprout-review
on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: sprout-foundry/sprout-agent@v1
        with:
          primary-provider: deepinfra
          primary-model: deepseek-ai/DeepSeek-V3.1
          github-token: ${{ secrets.GITHUB_TOKEN }}
          deepinfra-api-key: ${{ secrets.DEEPINFRA_API_KEY }}
```

## Modes

| Mode | Trigger | What it does |
|------|---------|-------------|
| `review` (default) | `pull_request` | Reviews the diff and posts inline comments + verdict (APPROVE / REQUEST_CHANGES / COMMENT). Does not modify code. |
| `fix` | Issue comment `/sprout-fix` or `workflow_dispatch` | Reads an issue, creates a branch, implements the change, opens a PR. |
| `plan` | Issue comment `/sprout-plan` or `workflow_dispatch` | Reads an issue and posts a structured implementation plan as a comment. |

## Inputs

### Required

| Input | Description |
|-------|-------------|
| `primary-provider` | Provider ID: `openai`, `openrouter`, `deepinfra`, `zai`, `chutes`, `mistral`, or a custom provider name. |
| `primary-model` | Model ID for the primary provider, e.g. `deepseek-ai/DeepSeek-V3.1`, `gpt-4o`, `GLM-5.0-Air`. |
| `github-token` | `${{ secrets.GITHUB_TOKEN }}` works for public repos. For PR creation in `fix` mode, use a PAT with `repo` scope. |

### Provider keys (set whichever you use)

| Input | Secret name |
|-------|------------|
| `openai-api-key` | `OPENAI_API_KEY` |
| `openrouter-api-key` | `OPENROUTER_API_KEY` |
| `deepinfra-api-key` | `DEEPINFRA_API_KEY` |
| `zai-api-key` | `ZAI_API_KEY` |
| `chutes-api-key` | `CHUTES_API_KEY` |
| `mistral-api-key` | `MISTRAL_API_KEY` |
| `jina-api-key` | `JINA_API_KEY` (web search) |
| `custom-provider-api-key` | `CUSTOM_PROVIDER_API_KEY` |

### Optional

| Input | Default | Description |
|-------|---------|-------------|
| `mode` | `review` | `review`, `fix`, or `plan`. |
| `sprout-version` | `latest` | Pin a specific sprout release tag, e.g. `v0.17.2`. |
| `coder-provider` / `coder-model` | (= primary) | Route the coder subagent to a different provider/model for cost control. |
| `reviewer-provider` / `reviewer-model` | (= primary) | Route the reviewer subagent to a different provider/model. |
| `review-type` | `comprehensive` | Review focus: `comprehensive`, `security`, or `performance`. |
| `comment-threshold` | `medium` | Inline comment severity floor: `high` (critical only), `medium` (+major), `low` (+minor/suggestion). |
| `max-iterations` | mode-specific | 120 for review, 240 for fix, 60 for plan. |
| `max-budget-usd` | `2.00` (review), `8.00` (fix) | Hard cap on LLM spend. |
| `budget-warn` | `0.5,0.8` | Warn at 50% and 80% of budget. |
| `timeout-minutes` | `15` (review), `45` (fix) | Wall-clock timeout. |
| `mcp` | `off` (review), `github` (fix) | Enable GitHub MCP server for the agent. |
| `trigger-phrase` | `/sprout-review`, `/sprout-fix`, `/sprout-plan` | Comment phrase per mode. Override for custom triggers. |
| `debug` | `false` | Verbose logging. |

### Custom provider (Groq, vLLM, LM Studio, etc.)

```yaml
- uses: sprout-foundry/sprout-agent@v1
  with:
    primary-provider: groq
    primary-model: llama-3.1-70b-versatile
    mode: review
    custom-provider-name: groq
    custom-provider-url: https://api.groq.com/openai/v1
    custom-provider-api-key: ${{ secrets.GROQ_API_KEY }}
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Outputs

| Output | Available in | Description |
|--------|-------------|-------------|
| `success` | all modes | `true` if the run produced output (review posted / PR created). |
| `cost` | all modes | Total LLM spend in USD, e.g. `0.039`. |
| `pr-number` | fix mode | PR number if a PR was created. |
| `pr-url` | fix mode | PR URL if a PR was created. |
| `branch-name` | fix mode | Branch name, e.g. `issue/42`. |

```yaml
- uses: sprout-foundry/sprout-agent@v1
  id: sprout
  with:
    mode: fix
    primary-provider: openai
    primary-model: gpt-4o
    github-token: ${{ secrets.GH_PAT }}
    openai-api-key: ${{ secrets.OPENAI_API_KEY }}
- run: echo "Cost: ${{ steps.sprout.outputs.cost }}, PR: ${{ steps.sprout.outputs.pr-url }}"
```

## Migration from ledit-agent

See [MIGRATION.md](MIGRATION.md) for the full input rename table. Key changes:

- `ai-provider` → `primary-provider`
- `ai-model` → `primary-model`
- `mode: solve` → `mode: fix`
- Provider keys now passed as inputs (not just env vars)
- `subagent-coder-provider` → `coder-provider` (plus `reviewer-provider`)

## Security

- The action needs `contents: write` for `fix` mode (pushes commits). `review` and `plan` need `contents: read` only.
- `fix` mode creates a branch named `issue/<N>` and pushes commits. Pin `max-budget-usd` low for untrusted repos.
- Self-PR detection: the action downgrades `APPROVE` / `REQUEST_CHANGES` to `COMMENT` when reviewing its own PRs.
