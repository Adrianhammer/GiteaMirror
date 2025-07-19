#!/usr/bin/env bash
set -euo pipefail

# Load .env if it exists
if [ -f .env ]; then
  export $(grep -v '^\s*#' .env | xargs)
fi

# Required environment variables
GITHUB_USERNAME="${GITHUB_USERNAME:?please set in .env}"
GITHUB_TOKEN="${GITHUB_TOKEN:?please set in .env}"
GITEA_URL="${GITEA_URL:?please set in .env}"       # e.g. http://192.168.1.119:3000
GITEA_USERNAME="${GITEA_USERNAME:?please set in .env}"
GITEA_TOKEN="${GITEA_TOKEN:?please set in .env}"

WORK_DIR="${WORK_DIR:-/tmp/gitea_mirror}"
LOG_FILE="${LOG_FILE:-/tmp/migration.log}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%F %T')]${NC} $1"  | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"   | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"    | tee -a "$LOG_FILE"; }

# Check dependencies
for dep in curl git jq; do
  command -v "$dep" >/dev/null || {
    echo "Please install $dep" >&2
    exit 1
  }
done

# Create repo on Gitea
create_gitea_repo() {
  local name="$1" desc="$2" priv="$3"
  # Escape quotes in description
  desc=${desc//\"/\\\"}
  log "Creating '$name' on Gitea..."
  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg desc "$desc" \
    --argjson priv "$priv" \
    '{name:$name,description:$desc,private:$priv,auto_init:false}')
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$GITEA_URL/api/v1/user/repos")
  if [[ $code == 201 ]]; then
    success "Created '$name'"
    return 0
  elif [[ $code == 409 ]]; then
    warning "'$name' already exists"
    return 0
  else
    error "Gitea API returned HTTP $code for '$name'"
    return 1
  fi
}

# Mirror one repo
mirror_repository() {
  local repo_json="$1"
  local name desc priv
  name=$(jq -r .name <<<"$repo_json")
  desc=$(jq -r '.description // ""' <<<"$repo_json")
  priv=$(jq -r .private <<<"$repo_json")

  log "Processing '$name'…"

  create_gitea_repo "$name" "$desc" "$priv" || return 1

  local dir="$WORK_DIR/$name"
  rm -rf "$dir"
  mkdir -p "$dir"

  # GitHub clone URL with token
  local gh_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${name}.git"
  git clone --mirror "$gh_url" "$dir" || {
    error "Clone failed for '$name'"
    return 1
  }

  # Build Gitea push URL, preserving scheme
  local base="${GITEA_URL%/}"             # strip trailing slash
  local creds="${GITEA_USERNAME}:${GITEA_TOKEN}@"
  local hostport="${base#*://}"           # drop scheme
  local push_url="${base/\/\//\/\/$creds}${hostport}/${GITEA_USERNAME,,}/${name}.git"

  cd "$dir"
  git push --mirror "$push_url" || {
    error "Push failed for '$name'"
    return 1
  }

  success "Mirrored '$name'"

  # Return to WORK_DIR for next iteration
  cd "$WORK_DIR"
}

# Main
main() {
  log "Starting GitHub → Gitea migration…"
  mkdir -p "$WORK_DIR"
  > "$LOG_FILE"

  log "Fetching list of repos from GitHub…"
  local all_repos="[]"
  local page=1

  while :; do
    local resp
    resp=$(curl -s \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/user/repos?page=$page&per_page=100&affiliation=owner&sort=updated")
    # break when empty
    [[ $(jq -r 'length' <<<"$resp") -eq 0 ]] && break
    all_repos=$(jq -s '.[0] + .[1]' <<<"$all_repos"$'\n'"$resp")
    ((page++))
  done

  local total
  total=$(jq length <<<"$all_repos")
  log "Found $total repositories to migrate"

  local ok=0 fail=0

  # Iterate in the main shell so counters stick
  while IFS= read -r repo; do
    if mirror_repository "$repo"; then
      ((ok++))
    else
      ((fail++))
    fi
  done < <(jq -c '.[]' <<<"$all_repos")

  # Cleanup
  rm -rf "$WORK_DIR"

  log "Migration complete: $ok succeeded, $fail failed"
}

main "$@"