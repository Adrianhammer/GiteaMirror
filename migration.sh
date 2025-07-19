#!/bin/bash

# GitHub to Gitea Migration Script
# This script fetches all repositories from GitHub and mirrors them to Gitea

set -e  # Exit on any error

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Configuration – set in .env or edit below
GITHUB_USERNAME="${GITHUB_USERNAME}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
GITEA_URL="${GITEA_URL}"
GITEA_USERNAME="${GITEA_USERNAME}"
GITEA_TOKEN="${GITEA_TOKEN}"

WORK_DIR="${WORK_DIR:-/tmp/gitea_mirror}"
LOG_FILE="${LOG_FILE:-/tmp/migration.log}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%F %T')]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"; }

check_dependencies() {
    for dep in curl git jq; do
        command -v "$dep" >/dev/null || { error "$dep not installed"; exit 1; }
    done
}

create_gitea_repo() {
    local repo_name="$1" desc="$2" private="$3"
    log "Creating repo '$repo_name' in Gitea..."
    local payload=$(jq -n \
        --arg name "$repo_name" \
        --arg desc "$desc" \
        --argjson private "$private" \
        '{name:$name, description:$desc, private:$private, auto_init:false}')
    local code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$GITEA_URL/api/v1/user/repos")
    [[ "$code" == "201" ]] && { success "Created $repo_name"; return 0; }
    [[ "$code" == "409" ]] && { warning "$repo_name already exists"; return 0; }
    error "Failed to create $repo_name (HTTP $code)"; return 1
}

mirror_repository() {
    local repo_data="$1"
    local repo_name=$(jq -r '.name' <<< "$repo_data")
    local desc=$(jq -r '.description // ""' <<< "$repo_data")
    local private=$(jq -r '.private' <<< "$repo_data")

    log "Processing $repo_name..."
    local clone_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${repo_name}.git"
    local gitea_remote="${GITEA_URL}/$(echo "$GITEA_USERNAME" | tr '[:upper:]' '[:lower:]')/${repo_name}.git"

    create_gitea_repo "$repo_name" "$desc" "$private" || return 1

    local repo_dir="$WORK_DIR/$repo_name"
    mkdir -p "$repo_dir"
    cd "$repo_dir"

    git clone --mirror "$clone_url" . || { error "Clone failed"; return 1; }
    git push --mirror "$gitea_remote" || { error "Push failed"; return 1; }

    success "Mirrored $repo_name"
    cd "$WORK_DIR"
    rm -rf "$repo_dir"
}

main() {
    log "Starting GitHub → Gitea migration..."
    check_dependencies

    [[ -z "$GITHUB_USERNAME" || -z "$GITHUB_TOKEN" \
       || -z "$GITEA_URL" || -z "$GITEA_TOKEN" ]] && {
        error "Missing required env vars"; exit 1
    }

    mkdir -p "$WORK_DIR"

    log "Fetching repositories from GitHub…"
    local all_repos="[]"
    local page=1

    while :; do
        local resp
        resp=$(curl -s \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/user/repos?page=$page&per_page=100&affiliation=owner&sort=updated")
        [[ $(jq -r 'length' <<<"$resp") -eq 0 ]] && break
        all_repos=$(jq -s '.[0] + .[1]' <<<"$all_repos"$'\n'"$resp")
        ((page++))
    done

    local repo_count
    repo_count=$(jq length <<<"$all_repos")
    log "Found $repo_count repositories to migrate"

    local success=0 errors=0

    while IFS= read -r repo_line; do
        mirror_repository "$repo_line" \
            && ((success++)) \
            || ((errors++))
    done < <(jq -c '.[]' <<<"$all_repos")

    rm -rf "$WORK_DIR"
    log "Migration complete: $success OK, $errors failed"
}

main "$@"