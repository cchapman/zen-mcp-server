# Upstream Sync Workflow Design

> **Goal:** Shell script + JSON tracking file to manage cherry-picking PRs from BeehiveInnovations/pal-mcp-server into cchapman/zen-mcp-server.

## Architecture

Single bash script (`upstream-sync.sh`) with subcommands. State tracked in `.upstream-sync.json` at repo root (gitignored). The script handles mechanical git operations; PR review and code adjustments happen in Claude Code conversation.

## Branch Strategy

```
main                        Stable — only merged integration branches
upstream-sync/YYYY-MM-DD    Integration branch for a session of cherry-picks
upstream/pr-<N>             Temporary per-PR branch for review & adjustment
```

Each sync session creates one integration branch off main. Multiple PRs are cherry-picked onto it. After all PRs are reviewed, adjusted, and tested, the integration branch is merged to main. This provides a clean rollback point per session.

## Commands

| Command | Purpose |
|---------|---------|
| `check` | Fetch upstream, show new commits + open PRs, update tracking |
| `start <PR#>` | Fetch PR branch, create `upstream/pr-<N>`, mark as reviewing |
| `apply <PR#>` | Squash-merge PR branch onto current branch (integration or main), clean up |
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
4. Claude fetches diff, analyzes, reports findings (quality, security, data exfiltration)
5. Claude creates integration branch (once per session): `git checkout -b upstream-sync/YYYY-MM-DD`
6. If approved: `./upstream-sync.sh start 400` → creates `upstream/pr-400` branch
7. Claude makes adjustments on the branch if needed, commits changes
8. `./upstream-sync.sh apply 400` → squash-merges onto integration branch
9. Repeat steps 2-8 for more PRs
10. Run full test suite on integration branch
11. Merge to main: `git checkout main && git merge upstream-sync/YYYY-MM-DD`
12. User pushes when ready

## Help text

Oriented toward Claude as the primary operator, with the typical workflow path documented.

## Requirements

- `jq` — JSON processing
- `gh` — GitHub CLI for PR listing and diff viewing
- `upstream` git remote pointing to BeehiveInnovations/pal-mcp-server
