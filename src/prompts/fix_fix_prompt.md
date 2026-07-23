# Fix Review Findings Prompt

The in-loop review has just finished and may have flagged findings.

## Read first

Open `${SPROUT_RUN_DIR}/review.json`. The `comments` array contains
the specific issues to address; each entry has file, line, body, and
severity.

## What to do

For each `critical` or `major` comment:
1. Open the cited file at the cited line.
2. Understand the actual problem (read the surrounding code — don't
   trust the comment at face value).
3. Apply a focused fix that resolves the issue. Don't refactor
   surrounding code.
4. Move to the next comment.

For each `minor` comment:
- Treat as advisory. Apply if the fix is local and obvious; skip if
  the change is risky or out-of-scope.

## Important constraints

- **Don't reintroduce fixes for things you already fixed.** Sometimes
  the review.json contains stale comments from a previous fix
  iteration. Cross-reference with `git log` and the actual current
  state — if the cited issue is already resolved, skip it.
- **Don't expand scope.** The original issue defines the goal. Don't
  add features, refactors, or improvements outside that scope.
- **Re-run the build** after your fixes (`go build ./...` or
  equivalent). If it breaks, fix it.

## After the fix loop

When all critical/major are addressed and the build passes, write a
brief confirmation to `${SPROUT_RUN_DIR}/fix_confirm.md`:

```markdown
# Fix Loop Confirmation

- **Critical addressed**: N
- **Major addressed**: M
- **Minor addressed**: K (or "skipped — out of scope")
- **Build status**: pass/fail
- **Notes**: any leftover concerns, deferred items
```

The action's post-commit hook uses this file to decide whether to
proceed with the PR creation.
