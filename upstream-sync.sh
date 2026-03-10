#!/usr/bin/env bash
set -euo pipefail

# upstream-sync.sh — Manage cherry-picks from upstream pal-mcp-server
#
# Typical workflow (Claude as operator):
#   1. User runs: ./upstream-sync.sh check
#   2. User picks a PR: "Review upstream PR #400 for quality and security"
#   3. Claude reviews the diff, reports findings
#   4. Claude runs: ./upstream-sync.sh start 400
#   5. Claude makes adjustments on the upstream/pr-400 branch
#   6. Claude runs: ./upstream-sync.sh apply 400
#
# For Claude: When asked to review a PR, use:
#   gh pr view <PR#> --repo BeehiveInnovations/pal-mcp-server
#   gh pr diff <PR#> --repo BeehiveInnovations/pal-mcp-server
# Then run 'start' to create the local branch for adjustments.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKING_FILE="$SCRIPT_DIR/.upstream-sync.json"
UPSTREAM_REPO="BeehiveInnovations/pal-mcp-server"
UPSTREAM_REMOTE="upstream"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────

ensure_tracking_file() {
    if [[ ! -f "$TRACKING_FILE" ]]; then
        cat > "$TRACKING_FILE" <<'INIT'
{
  "upstream_repo": "BeehiveInnovations/pal-mcp-server",
  "last_check": null,
  "last_upstream_sha": null,
  "prs": {}
}
INIT
    fi
}

require_jq() {
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required. Install with: brew install jq${NC}"
        exit 1
    fi
}

require_gh() {
    if ! command -v gh &>/dev/null; then
        echo -e "${RED}Error: GitHub CLI (gh) is required. Install with: brew install gh${NC}"
        exit 1
    fi
}

ensure_upstream_remote() {
    if ! git remote get-url "$UPSTREAM_REMOTE" &>/dev/null; then
        echo -e "${YELLOW}Adding upstream remote...${NC}"
        git remote add "$UPSTREAM_REMOTE" "https://github.com/$UPSTREAM_REPO.git"
    fi
}

get_pr_status() {
    local pr_num="$1"
    jq -r --arg pr "$pr_num" '.prs[$pr].status // "unknown"' "$TRACKING_FILE"
}

set_pr_field() {
    local pr_num="$1" field="$2" value="$3"
    local tmp
    tmp=$(mktemp)
    jq --arg pr "$pr_num" --arg field "$field" --arg val "$value" \
        '.prs[$pr][$field] = $val' "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"
}

set_pr_object() {
    local pr_num="$1"
    shift
    local tmp
    tmp=$(mktemp)
    # Build the object from key=value pairs
    local jq_args=()
    local jq_sets=()
    local i=0
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        jq_args+=(--arg "k$i" "$key" --arg "v$i" "$val")
        jq_sets+=(".prs[\$pr][\"\\(\$k$i)\"] = \$v$i")
        ((i++))
        shift
    done
    local jq_expr
    jq_expr=$(printf ' | %s' "${jq_sets[@]}")
    jq_expr="${jq_expr:3}" # strip leading ' | '
    jq --arg pr "$pr_num" "${jq_args[@]}" "$jq_expr" "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"
}

update_last_check() {
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg sha "$(git rev-parse "$UPSTREAM_REMOTE/main" 2>/dev/null || echo "unknown")" \
       '.last_check = $ts | .last_upstream_sha = $sha' "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"
}

status_icon() {
    case "$1" in
        applied)   echo -e "${GREEN}done${NC}" ;;
        reviewing) echo -e "${CYAN}revw${NC}" ;;
        skipped)   echo -e "${RED}skip${NC}" ;;
        pending)   echo -e "${YELLOW}pend${NC}" ;;
        *)         echo -e "${BLUE} NEW${NC}" ;;
    esac
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_check() {
    ensure_upstream_remote

    echo -e "${BOLD}=== Upstream Sync Check ===${NC}"
    echo ""

    # Fetch upstream
    echo -e "${CYAN}Fetching upstream...${NC}"
    git fetch "$UPSTREAM_REMOTE" --quiet
    echo ""

    # Compare commits
    local last_sha
    last_sha=$(jq -r '.last_upstream_sha // ""' "$TRACKING_FILE")
    if [[ -n "$last_sha" && "$last_sha" != "null" ]]; then
        local new_commits
        new_commits=$(git log --oneline "$last_sha..upstream/main" 2>/dev/null | head -20)
        if [[ -n "$new_commits" ]]; then
            echo -e "${BOLD}New upstream commits since last check:${NC}"
            echo "$new_commits"
        else
            echo -e "New upstream commits since last check: ${GREEN}none${NC}"
        fi
    else
        echo -e "${YELLOW}First check — no previous SHA to compare${NC}"
    fi
    echo ""

    # Get open PRs
    echo -e "${BOLD}Open PRs on ${UPSTREAM_REPO}:${NC}"
    echo ""

    local pr_json
    pr_json=$(gh pr list --repo "$UPSTREAM_REPO" --state open --limit 50 \
        --json number,title,author,createdAt,changedFiles,additions,deletions \
        2>/dev/null || echo "[]")

    local pr_count
    pr_count=$(echo "$pr_json" | jq 'length')

    # Track counts
    local count_new=0 count_pending=0 count_reviewing=0 count_applied=0 count_skipped=0

    echo "$pr_json" | jq -c '.[] | {number, title, author: .author.login, additions, deletions}' | while read -r pr; do
        local num title author adds dels status
        num=$(echo "$pr" | jq -r '.number')
        title=$(echo "$pr" | jq -r '.title')
        author=$(echo "$pr" | jq -r '.author')
        adds=$(echo "$pr" | jq -r '.additions')
        dels=$(echo "$pr" | jq -r '.deletions')
        status=$(get_pr_status "$num")

        if [[ "$status" == "unknown" ]]; then
            # New PR — add to tracking
            local tmp
            tmp=$(mktemp)
            jq --arg pr "$num" --arg title "$title" --arg author "$author" \
                '.prs[$pr] = {"status": "pending", "title": $title, "author": $author}' \
                "$TRACKING_FILE" > "$tmp"
            mv "$tmp" "$TRACKING_FILE"
            status="new"
        fi

        local icon
        icon=$(status_icon "$status")
        printf "  %b  #%-4s  +%-4s -%-4s  @%-20s %s\n" "$icon" "$num" "$adds" "$dels" "$author" "$title"
    done

    echo ""

    # Summary counts
    local applied pending reviewing skipped
    applied=$(jq '[.prs[] | select(.status == "applied")] | length' "$TRACKING_FILE")
    reviewing=$(jq '[.prs[] | select(.status == "reviewing")] | length' "$TRACKING_FILE")
    pending=$(jq '[.prs[] | select(.status == "pending")] | length' "$TRACKING_FILE")
    skipped=$(jq '[.prs[] | select(.status == "skipped")] | length' "$TRACKING_FILE")

    echo -e "${BOLD}Tracked:${NC} ${GREEN}${applied} applied${NC}, ${CYAN}${reviewing} reviewing${NC}, ${YELLOW}${pending} pending${NC}, ${RED}${skipped} skipped${NC}"

    # Update last check
    update_last_check
}

cmd_start() {
    local pr_num="${1:-}"
    if [[ -z "$pr_num" ]]; then
        echo -e "${RED}Usage: $0 start <PR#>${NC}"
        exit 1
    fi

    ensure_upstream_remote

    local branch_name="upstream/pr-${pr_num}"

    # Get PR info
    echo -e "${CYAN}Fetching PR #${pr_num} info...${NC}"
    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$UPSTREAM_REPO" \
        --json title,author,headRefName,headRepository,commits,changedFiles,additions,deletions \
        2>/dev/null)

    if [[ -z "$pr_info" ]]; then
        echo -e "${RED}Error: Could not fetch PR #${pr_num}${NC}"
        exit 1
    fi

    local title author head_ref head_repo adds dels files
    title=$(echo "$pr_info" | jq -r '.title')
    author=$(echo "$pr_info" | jq -r '.author.login')
    head_ref=$(echo "$pr_info" | jq -r '.headRefName')
    head_repo=$(echo "$pr_info" | jq -r '.headRepository.owner.login + "/" + .headRepository.name')
    adds=$(echo "$pr_info" | jq -r '.additions')
    dels=$(echo "$pr_info" | jq -r '.deletions')
    files=$(echo "$pr_info" | jq -r '.changedFiles')

    echo -e "${BOLD}PR #${pr_num}: ${title}${NC}"
    echo -e "  Author: @${author}"
    echo -e "  Branch: ${head_ref} (${head_repo})"
    echo -e "  Changes: ${files} files, +${adds} -${dels}"
    echo ""

    # Fetch the PR branch via GitHub's pull ref (works even if fork is deleted/renamed)
    echo -e "${CYAN}Fetching PR branch...${NC}"
    git fetch "$UPSTREAM_REMOTE" "pull/${pr_num}/head:${branch_name}" --quiet
    git checkout "$branch_name"

    # Make sure we're on the new branch
    git checkout "$branch_name" 2>/dev/null || true

    # Update tracking
    local tmp
    tmp=$(mktemp)
    jq --arg pr "$pr_num" --arg title "$title" --arg author "$author" \
       --arg branch "$branch_name" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.prs[$pr] = {
            "status": "reviewing",
            "title": $title,
            "author": $author,
            "branch": $branch,
            "started_at": $ts
        }' "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"

    echo ""
    echo -e "${GREEN}Branch '${branch_name}' created and checked out.${NC}"
    echo ""
    echo -e "${BOLD}Next steps for Claude:${NC}"
    echo -e "  1. Review: gh pr diff ${pr_num} --repo ${UPSTREAM_REPO}"
    echo -e "  2. Make adjustments on this branch as needed"
    echo -e "  3. When ready: ./upstream-sync.sh apply ${pr_num}"
}

cmd_apply() {
    local pr_num="${1:-}"
    if [[ -z "$pr_num" ]]; then
        echo -e "${RED}Usage: $0 apply <PR#>${NC}"
        exit 1
    fi

    local branch_name="upstream/pr-${pr_num}"
    local status
    status=$(get_pr_status "$pr_num")

    if [[ "$status" != "reviewing" ]]; then
        echo -e "${RED}Error: PR #${pr_num} is not in 'reviewing' status (current: ${status})${NC}"
        echo -e "Run './upstream-sync.sh start ${pr_num}' first."
        exit 1
    fi

    # Check the branch exists
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        echo -e "${RED}Error: Branch '${branch_name}' not found${NC}"
        exit 1
    fi

    # Get PR info for commit message
    local title author
    title=$(jq -r --arg pr "$pr_num" '.prs[$pr].title' "$TRACKING_FILE")
    author=$(jq -r --arg pr "$pr_num" '.prs[$pr].author' "$TRACKING_FILE")

    # Switch to main
    echo -e "${CYAN}Switching to main...${NC}"
    git checkout main

    # Squash merge
    echo -e "${CYAN}Squash-merging ${branch_name}...${NC}"
    git merge --squash "$branch_name"

    # Commit with attribution
    git commit -m "$(cat <<EOF
${title}

Cherry-picked from upstream PR ${UPSTREAM_REPO}#${pr_num}
Original author: @${author}
EOF
)"

    # Delete the branch
    git branch -D "$branch_name"

    # Update tracking
    local tmp
    tmp=$(mktemp)
    jq --arg pr "$pr_num" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.prs[$pr].status = "applied" | .prs[$pr].applied_at = $ts | .prs[$pr].branch = null' \
       "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"

    echo ""
    echo -e "${GREEN}PR #${pr_num} applied to main.${NC}"
    echo -e "  Commit: $(git log --oneline -1)"
    echo ""
    echo -e "${BOLD}Remember:${NC} Push when ready with 'git push origin main'"
}

cmd_skip() {
    local pr_num="${1:-}"
    local reason="${2:-no reason given}"

    if [[ -z "$pr_num" ]]; then
        echo -e "${RED}Usage: $0 skip <PR#> [\"reason\"]${NC}"
        exit 1
    fi

    local title
    title=$(jq -r --arg pr "$pr_num" '.prs[$pr].title // "unknown"' "$TRACKING_FILE")

    local tmp
    tmp=$(mktemp)
    jq --arg pr "$pr_num" --arg reason "$reason" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.prs[$pr].status = "skipped" | .prs[$pr].reason = $reason | .prs[$pr].skipped_at = $ts' \
       "$TRACKING_FILE" > "$tmp"
    mv "$tmp" "$TRACKING_FILE"

    echo -e "${RED}Skipped${NC} PR #${pr_num}: ${title}"
    echo -e "  Reason: ${reason}"
}

cmd_status() {
    echo -e "${BOLD}=== Upstream Sync Status ===${NC}"
    echo ""

    local last_check
    last_check=$(jq -r '.last_check // "never"' "$TRACKING_FILE")
    echo -e "Last check: ${last_check}"
    echo ""

    # Group by status
    for status_type in reviewing pending applied skipped; do
        local items
        items=$(jq -r --arg s "$status_type" \
            '.prs | to_entries[] | select(.value.status == $s) | "\(.key)\t\(.value.title)\t\(.value.author // "")\t\(.value.reason // "")"' \
            "$TRACKING_FILE" 2>/dev/null)

        if [[ -n "$items" ]]; then
            local icon
            icon=$(status_icon "$status_type")
            echo -e "${BOLD}${status_type^}:${NC}"
            while IFS=$'\t' read -r num title author reason; do
                printf "  %b  #%-4s  @%-16s  %s" "$icon" "$num" "$author" "$title"
                if [[ -n "$reason" ]]; then
                    echo -e " ${RED}(${reason})${NC}"
                else
                    echo ""
                fi
            done <<< "$items"
            echo ""
        fi
    done
}

cmd_help() {
    cat <<'HELP'
upstream-sync.sh — Manage cherry-picks from upstream pal-mcp-server

━━━ For Claude (typical workflow) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  User runs:  ./upstream-sync.sh check
  User says:  "Review PR #400 for quality and security concerns"

  Claude should then:
    1. Review the PR diff:
         gh pr diff 400 --repo BeehiveInnovations/pal-mcp-server
         gh pr view 400 --repo BeehiveInnovations/pal-mcp-server
    2. Report findings (quality, security, data exfiltration risks)
    3. If approved by user, create the local branch:
         ./upstream-sync.sh start 400
    4. Make any needed adjustments on the upstream/pr-400 branch
    5. Run tests: ./code_quality_checks.sh
    6. When ready, squash-merge to main:
         ./upstream-sync.sh apply 400
    7. Do NOT push — user decides when to push

━━━ Commands ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  check               Fetch upstream, show new commits + open PRs
  start <PR#>         Fetch PR branch → upstream/pr-<N>, mark reviewing
  apply <PR#>         Squash-merge PR branch to main, clean up
  skip <PR#> [reason] Mark PR as skipped (won't show as NEW again)
  status              Show all tracked PRs grouped by status
  help                Show this help

━━━ Files ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  .upstream-sync.json  Tracking state (PR statuses, timestamps)
  upstream remote      Points to BeehiveInnovations/pal-mcp-server

HELP
}

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    require_jq
    require_gh
    ensure_tracking_file

    cd "$SCRIPT_DIR"

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        check)  cmd_check "$@" ;;
        start)  cmd_start "$@" ;;
        apply)  cmd_apply "$@" ;;
        skip)   cmd_skip "$@" ;;
        status) cmd_status "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            echo -e "${RED}Unknown command: ${cmd}${NC}"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
