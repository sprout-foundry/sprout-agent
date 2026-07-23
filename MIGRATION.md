# Migration guide: `ledit-agent` → `sprout-agent`

`alantheprice/ledit-agent@v1` is replaced by `sprout-foundry/sprout-agent@v1`.
This guide maps every old input/output to its new name.

## TL;DR — find and replace

| from | to |
|---|---|
| `uses: alantheprice/ledit-agent@<sha>` | `uses: sprout-foundry/sprout-agent@<sha>` |
| `mode: solve` | `mode: fix` |
| `mode: review` | `mode: review` (unchanged) |
| `mode: plan` | `mode: plan` (unchanged — also new; was never supported) |
| `ai-provider: <X>` | `primary-provider: <X>` |
| `ai-model: <Y>` | `primary-model: <Y>` |
| `coder-provider: <X>` | `coder-provider: <X>` (unchanged, new default if unset) |
| `coder-model: <Y>` | `coder-model: <Y>` (unchanged) |
| `reviewer-provider: <X>` | `reviewer-provider: <X>` (unchanged) |
| `reviewer-model: <Y>` | `reviewer-model: <Y>` (unchanged) |
| `max-cost-usd: 5` | `max-budget-usd: 5.00` |
| `cost-warning-at: 0.5` | `budget-warn: 0.5` |
| `mcp: github` | `mcp: github` (unchanged — off by default in review mode now) |
| `LEDIT_COST` (output) | `cost` (action output, no env prefix) |
| `LEDIT_VERBOSE` env | `DEBUG: true` input |

Anything not listed is unchanged.

## What's different beyond renaming

- `mode: solve` was a thin wrapper around `run_ledit_workflow.sh` with three
  orchestration steps. The new `mode: fix` is a five-step pipeline that
  adds dedicated tester + reviewer subagents and a build gate. Expect
  higher-quality output and slightly higher cost per run.
- The `GitHub MCP` server is no longer enabled by default in review mode.
  It was the largest cost driver in the old review run; review works
  without it (the Action uses `gh api` and `curl` directly). To re-enable
  it, pass `mcp: github`.
- Outputs are emitted through `$GITHUB_OUTPUT` rather than printed to
  stdout. Update any downstream steps that parsed stdout.
- Errors are surfaced via `$GITHUB_STEP_SUMMARY` so CI dashboards show a
  readable summary. Set `debug: true` to enable debug logging.
- The `pr-number`, `pr-url`, `branch-name`, and `cost` outputs are
  properly declared on `action.yml` and accessible from downstream
  workflow steps as `${{ steps.sprout.outputs.pr-number }}` and similar.

## Behavior changes

### review mode

- **Cheaper.** Default `max-budget-usd` dropped from $5 to $2 in review
  mode. Override if you need more headroom.
- **No MCP by default.** As above — the GitHub MCP is auto-on only in
  `fix` mode. Review fetches PR metadata via the GitHub REST API directly.

### fix mode

- **Build gates.** A shell-level `build` step is wired in by default:
  Go projects run `go build ./...`, Node projects run `npm run build`,
  Rust projects run `cargo check`, Python projects run
  `python -m compileall -q .`. If none of those markers are present,
  the step is a no-op. There is no input to override the build command
  — fork the action if you need custom build logic.
- **Auto-PR.** When the implementation produces changes, the Action
  opens a PR automatically via `sprout pr --skip-prompt`. If that fails
  (e.g. `sprout pr` not on PATH), the action falls back to `gh pr create`.
  There is no input to disable PR creation — re-run the action with the
  workflow step checked out manually to override.
- **Default branch auto-detected.** The PR's base branch is the repo's
  default branch (resolved by `sprout pr` via `git.GetDefaultBranch`),
  not hardcoded to `main`.
- **Re-runnable.** A re-run after partial failure commits the remaining
  work without spamming commits (the fix shell always stages `git add -A`
  and produces a single commit on the existing `issue/N` branch).

### plan mode

- **New.** The `plan` mode is a single-shot mode that posts a structured
  plan as an issue comment and writes `plan.md` to the run dir. Useful
  for kicking off `/sprout-plan` comments that surface a structured plan
  before committing to the heavier fix run.

## What was removed

There is no backward-compat shim in v1. The legacy `mode: solve` input
**will fail** with `Unknown mode: solve`. Update your workflows before
upgrading. The legacy input names listed above (e.g. `ai-provider`) are
also rejected — rename to the new names.

If your workflow depended on undocumented behavior from `ledit-agent`
that's not listed here, open an issue and we can usually restore it in a
minor release.
