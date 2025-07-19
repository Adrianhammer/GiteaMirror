#!/usr/bin/env bash
set -euo pipefail

# --- Load .env if present ----------------------------------
if [ -f .env ]; then
  export $(grep -v '^\s*#' .env | xargs)
fi

# --- Config (override via .env) ---------------------------
GITHUB_USERNAME="${GITHUB_USERNAME:?}"
GITHUB_TOKEN="${GITHUB_TOKEN:?}"
GITEA_URL="${GITEA_URL:?}"           # e.g. http://192.168.1.119:3000
GITEA_USERNAME="${GITEA_USERNAME:?}"
GITEA_TOKEN="${GITEA_TOKEN:?}"

WORK_DIR="${WORK_DIR:-/tmp/gitea_mirror}"
LOG_FILE="${LOG_FILE:-/tmp/migration.log}"

# --- Colors ------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%F %T')]${NC} $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"  | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"   | tee -a "$LOG_FILE"; }

# --- Ensure deps ------------------------------------------
for dep in curl git jq; do
  command -v "$dep" >/dev/null \
    || { echo "Please install $dep" >&2; exit 1; }
done

# --- Create a repo on Gitea via API -----------------------
create_gitea_repo() {
  local name="$1" desc="$2" priv="$3"
  log "→ Creating '$name' on Gitea..."
  # escape description
  desc=${desc//\"/\\\"}
  local payload
  payload=$(
    jq -n \
      --arg name "$name" \
      --arg desc "$desc" \
      --argjson priv "$priv" \
      '{name:$name,description:$desc,private:$priv,auto_init:false}'
  )
  local code
  code=$(
    curl -s -w "%{http_code}" -o /dev/null -X POST \
      -H "Authorization: token $GITEA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$GITEA_URL/api/v1/user/repos"
  )
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

# --- Mirror one repo --------------------------------------
mirror_repository() {
  local repo_json="$1"
  local name desc priv
  name=$(jq -r .name <<<"$repo_json")
  desc=$(jq -r '.description // ""' <<<"$repo_json")
  priv=$(jq -r .private <<<"$repo_json")

  log "→ Processing '$name'…"
  create_gitea_repo "$name" "$desc" "$priv" || return 1

  local dir="$WORK_DIR/$name"
  # Remove any previous clone
  rm -rf "$dir"

  # Clone **into** $dir
  git clone --mirror "https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${name}.git" \
    "$dir" \
    || { error "Clone failed for '$name'"; return 1; }

  # Push from inside that new mirror
  cd "$dir"
  git push --mirror \
    "https://${GITEA_USERNAME}:${GITEA_TOKEN}@${GITEA_URL#*://}/${GITEA_USERNAME,,}/${name}.git" \
    || { error "Push failed for '$name'"; return 1; }

  success "Mirrored '$name'"
}

# --- Main --------------------------------------------------
main() {
  log "Starting GitHub → Gitea migration…"
  mkdir -p "$WORK_DIR"

  log "Fetching list of repos from GitHub…"
  local all_repos="[]"
  local page=1

  while :; do
    local resp
    resp=$(curl -s \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/user/repos?page=$page&per_page=100&affiliation=owner&sort=updated")

    # if no items, break
    [[ $(jq -r 'length' <<<"$resp") -eq 0 ]] && break

    # merge arrays
    all_repos=$(jq -s '.[0] + .[1]' <<<"$all_repos"$'\n'"$resp")

    ((page++))
  done

  local total
  total=$(jq length <<<"$all_repos")
  log "Found $total repositories to migrate"

  local success_count=0 error_count=0

  # process in main shell so counters stick
  while IFS= read -r repo; do
    if mirror_repository "$repo"; then
      ((success_count++))
    else
      ((error_count++))
    fi
  done < <(jq -c '.[]' <<<"$all_repos")

  # final cleanup
  rm -rf "$WORK_DIR"
  log "Migration complete: $success_count succeeded, $error_count failed"
}

main "$@"