# sprout-agent

GitHub Action that runs the [sprout](https://github.com/sprout-foundry/sprout) AI agent to review, fix, or plan work on a pull request.

This is the successor to [`alantheprice/ledit-agent`](https://github.com/alantheprice/ledit-agent), reimplemented against the current sprout CLI.

## Usage

### Code review (default)

```yaml
name: sprout-review
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: sprout-foundry/sprout-agent@v1
        with:
          primary-model: openai/gpt-4o
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

`review` mode posts a single review comment summarizing findings. It does not modify code.

### Auto-fix

```yaml
- uses: sprout-foundry/sprout-agent@v1
  with:
    primary-model: openai/gpt-4o
    mode: fix
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

`fix` mode pushes commits back to the same branch.

### Planning

```yaml
- uses: sprout-foundry/sprout-agent@v1
  with:
    primary-model: openai/gpt-4o
    mode: plan
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

`plan` mode writes a structured plan to the run log (no PR comment, no commits).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `primary-model` | ✅ | — | Model identifier, e.g. `openai/gpt-4o`, `anthropic/claude-3-7-sonnet`, `ollama/qwen2.5-coder`. |
| `mode` | | `review` | `review`, `fix`, or `plan`. |
| `github-token` | | `${{ github.token }}` | Token with `contents: write` and `pull-requests: write` scopes. |
| `max-iterations` | | `5` | Max agent iterations before force-stopping. |
| `max-budget-usd` | | `2.00` | Hard cap on LLM spend for this run. |
| `budget-warn` | | `0.5,0.8` | Comma-separated fractions of the budget at which to log warnings. |
| `timeout-minutes` | | `15` | Hard timeout for the whole run. |
| `mcp` | | `off` (`github` for `fix`) | MCP servers to enable. `github` enables the GitHub MCP server. |
| `trigger-phrase` | | `@sprout` | Phrase that triggers comment-driven runs (review/fix/plan by comment intent). |
| `review-type` | | `all` | Filter review findings by type. One of `all`, `security`, `correctness`, `performance`, `style`, `design`, `suggestion`. |
| `comment-threshold` | | `medium` | Minimum severity for a finding to be posted as a PR comment. One of `nit`, `low`, `medium`, `high`, `critical`. |
| `custom-provider-name` | | — | Register a custom OpenAI-compatible provider. Both `custom-provider-name` and `custom-provider-url` must be set. |
| `custom-provider-url` | | — | Base URL for the custom provider (e.g. `http://localhost:1234/v1`). |
| `custom-provider-model` | | (= `primary-model`) | Model name passed to the custom provider. |
| `custom-provider-api-key` | | — | API key for the custom provider. |
| `debug` | | `false` | Set `true` to enable verbose logging. |

### Outputs

| Output | Description |
|---|---|
| `cost` | Total LLM spend in USD for this run, e.g. `$0.0412`. |

```yaml
- uses: sprout-foundry/sprout-agent@v1
  id: sprout
  with:
    primary-model: openai/gpt-4o
- run: echo "Sprout cost: ${{ steps.sprout.outputs.cost }}"
```

### Custom provider example

```yaml
- uses: sprout-foundry/sprout-agent@v1
  with:
    primary-model: qwen2.5-coder
    mode: fix
    custom-provider-name: lmstudio
    custom-provider-url: http://host.docker.internal:1234/v1
    custom-provider-model: qwen2.5-coder-7b-instruct
    max-budget-usd: "0.50"
```

## Security

- The action never reads `secrets.*` directly — pass `github-token` explicitly.
- `fix` mode can push commits back to the same branch. Pin `max-iterations` and `max-budget-usd` low for untrusted PRs from forks.
- Self-PR detection: when the agent detects it is reviewing its own commits (e.g. `fix` followed by `review`), it downgrades `APPROVE` / `REQUEST_CHANGES` decisions to `COMMENT` to avoid rubber-stamping.

## Cost

Cost is reported via `${{ steps.sprout.outputs.cost }}` and emitted to the run log. Configure `max-budget-usd` and `timeout-minutes` to bound exposure on busy repos.