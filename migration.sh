#!/bin/bash

# GitHub to Gitea Migration Script
# This script fetches all repositories from GitHub and mirrors them to Gitea

set -e  # Exit on any error

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Configuration - UPDATE THESE VALUES
GITHUB_USERNAME="${GITHUB_USERNAME}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
GITEA_URL="${GITEA_URL}" 
GITEA_USERNAME="${GITEA_USERNAME}"
GITEA_TOKEN="${GITEA_TOKEN}"

# Working directory for temporary clones
WORK_DIR="${WORK_DIR}"
LOG_FILE="${LOG_FILE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if required tools are installed
check_dependencies() {
    local deps=("curl" "git" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed. Please install it first."
            exit 1
        fi
    done
}

# Create Gitea repository
create_gitea_repo() {
    local repo_name="$1"
    local repo_description="$2"
    local is_private="$3"
    
    log "Creating repository '$repo_name' in Gitea..."
    
    local response=$(curl -s -w "%{http_code}" -o /tmp/gitea_response.json \
        -X POST \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$repo_name\",
            \"description\": \"$repo_description\",
            \"private\": $is_private,
            \"auto_init\": false
        }" \
        "$GITEA_URL/api/v1/user/repos")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "201" ]]; then
        success "Repository '$repo_name' created successfully in Gitea"
        return 0
    elif [[ "$http_code" == "409" ]]; then
        warning "Repository '$repo_name' already exists in Gitea"
        return 0
    else
        error "Failed to create repository '$repo_name' in Gitea (HTTP $http_code)"
        cat /tmp/gitea_response.json
        return 1
    fi
}

# Get all GitHub repositories
get_github_repos() {
    log "Fetching repositories from GitHub..."
    
    local page=1
    local all_repos=""
    
    while true; do
        local response=$(curl -s \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/user/repos?page=$page&per_page=100&type=owner&sort=updated")
        
        local repos=$(echo "$response" | jq -r '.[].name // empty')
        
        if [[ -z "$repos" ]]; then
            break
        fi
        
        all_repos="$all_repos$repos"$'\n'
        ((page++))
    done
    
    echo "$all_repos" | grep -v '^$'
}

# Mirror a single repository
mirror_repository() {
    local repo_name="$1"
    local repo_data="$2"
    
    log "Processing repository: $repo_name"
    
    # Extract repository information
    local description=$(echo "$repo_data" | jq -r '.description // ""')
    local is_private=$(echo "$repo_data" | jq -r '.private')
    local clone_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${repo_name}.git"
    local gitea_remote="http://${GITEA_USERNAME}:${GITEA_TOKEN}@${GITEA_URL#http://}/$(echo "$GITEA_USERNAME" | tr '[:upper:]' '[:lower:]')/${repo_name}.git"
    
    # Create directory for this repo
    local repo_dir="$WORK_DIR/$repo_name"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    
    # Create repository in Gitea first
    if ! create_gitea_repo "$repo_name" "$description" "$is_private"; then
        error "Failed to create repository in Gitea, skipping..."
        return 1
    fi
    
    # Clone from GitHub
    log "Cloning $repo_name from GitHub..."
    if ! git clone --mirror "$clone_url" .; then
        error "Failed to clone $repo_name from GitHub"
        return 1
    fi
    
    # Push to Gitea
    log "Pushing $repo_name to Gitea..."
    if git push --mirror "$gitea_remote"; then
        success "Successfully mirrored $repo_name to Gitea"
    else
        error "Failed to push $repo_name to Gitea"
        return 1
    fi
    
    # Cleanup
    cd "$WORK_DIR"
    rm -rf "$repo_dir"
}

# Main migration function
main() {
    log "Starting GitHub to Gitea migration..."
    
    # Check dependencies
    check_dependencies
    
    # Validate configuration
    if [[ -z "$GITHUB_USERNAME" || "$GITHUB_USERNAME" == "your_github_username" ]]; then
        error "Please update GITHUB_USERNAME in the script"
        exit 1
    fi
    
    if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "your_github_personal_access_token" ]]; then
        error "Please update GITHUB_TOKEN in the script"
        exit 1
    fi
    
    if [[ -z "$GITEA_URL" || "$GITEA_URL" == "http://your_gitea_ip:3000" ]]; then
        error "Please update GITEA_URL in the script"
        exit 1
    fi
    
    if [[ -z "$GITEA_TOKEN" || "$GITEA_TOKEN" == "your_gitea_access_token" ]]; then
        error "Please update GITEA_TOKEN in the script"
        exit 1
    fi
    
    # Create working directory
    mkdir -p "$WORK_DIR"
    
    # Get all repositories from GitHub
    local repos=$(get_github_repos)
    local repo_count=$(echo "$repos" | wc -l)
    
    log "Found $repo_count repositories to migrate"
    
    # Process each repository
    local success_count=0
    local error_count=0
    
    while IFS= read -r repo_name; do
        if [[ -n "$repo_name" ]]; then
            # Get detailed repo info
            local repo_data=$(curl -s \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "https://api.github.com/repos/${GITHUB_USERNAME}/${repo_name}")
            
            if mirror_repository "$repo_name" "$repo_data"; then
                ((success_count++))
            else
                ((error_count++))
            fi
        fi
    done <<< "$repos"
    
    # Cleanup working directory
    rm -rf "$WORK_DIR"
    
    # Summary
    log "Migration completed!"
    log "Successfully migrated: $success_count repositories"
    log "Errors: $error_count repositories"
    
    if [[ $error_count -gt 0 ]]; then
        warning "Some repositories failed to migrate. Check the log file: $LOG_FILE"
        exit 1
    else
        success "All repositories migrated successfully!"
    fi
}

# Run the main function
main "$@"