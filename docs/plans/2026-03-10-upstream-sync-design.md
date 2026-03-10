# Upstream Sync Workflow Design

> **Goal:** Shell script + JSON tracking file to manage cherry-picking PRs from BeehiveInnovations/pal-mcp-server into cchapman/zen-mcp-server.

## Architecture

Single bash script (`upstream-sync.sh`) with subcommands. State tracked in `.upstream-sync.json` at repo root (gitignored). The script handles mechanical git operations; PR review and code adjustments happen in Claude Code conversation.

## Commands

| Command | Purpose |
|---------|---------|
| `check` | Fetch upstream, show new commits + open PRs, update tracking |
| `start <PR#>` | Fetch PR branch, create `upstream/pr-<N>`, mark as reviewing |
| `apply <PR#>` | Squash-merge PR branch to main, clean up, mark as applied |
| `skip <PR#> "<reason>"` | Mark PR as skipped with reason |
| `status` | Show current state of all tracked PRs |

## JSON Schema

```json
{
  "last_check": "ISO-8601 timestamp",
  "last_upstream_sha": "commit SHA",
  "prs": {
    "<number>": {
      "status": "pending|reviewing|applied|skipped",
      "title": "PR title",
      "author": "github username",
      "branch": "upstream/pr-<number>",
      "reason": "skip reason (if skipped)",
      "notes": "adjustment notes (if applied)",
      "started_at": "ISO-8601",
      "applied_at": "ISO-8601"
    }
  }
}
```

## Workflow

1. User runs `./upstream-sync.sh check`
2. User identifies interesting PR
3. User asks Claude to review it: "Review upstream PR #400 for quality and security"
4. Claude fetches diff, analyzes, reports findings
5. If approved: `./upstream-sync.sh start 400` → creates branch
6. Claude makes adjustments on the branch if needed
7. `./upstream-sync.sh apply 400` → squash-merges to main

## Help text

Oriented toward Claude as the primary operator, with the typical workflow path documented.
