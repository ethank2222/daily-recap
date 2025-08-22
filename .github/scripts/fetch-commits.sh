#!/bin/bash

# Fetch commits from the previous workday across all accessible repositories

set -euo pipefail

# Set timezone to Pacific Time
export TZ='America/Los_Angeles'

# Get the date range in Pacific Time
if [ "$(date +%u)" -eq 1 ]; then
    # It's Monday, look at Friday
    SINCE_DATE=$(date -d "last Friday" +%Y-%m-%d)
    UNTIL_DATE=$(date -d "last Saturday" +%Y-%m-%d)
else
    # Look at yesterday
    SINCE_DATE=$(date -d "yesterday" +%Y-%m-%d)
    UNTIL_DATE=$(date +%Y-%m-%d)
fi

echo "Fetching commits from $SINCE_DATE to $UNTIL_DATE (Pacific Time) across ALL branches"

# Temporary file to store commit data
COMMITS_FILE="/tmp/commits_data.json"
echo "[]" > "$COMMITS_FILE"

# Get the authenticated user
USER=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user" | jq -r '.login' || echo "")

if [ -z "$USER" ] || [ "$USER" = "null" ]; then
    echo "Error: Failed to authenticate with GitHub. Please check TOKEN_GITHUB" >&2
    exit 1
fi

echo "Fetching commits for user: $USER from all branches"

# Function to fetch commits from a repository
fetch_repo_commits() {
    local repo_url=$1
    local repo_name=$(echo "$repo_url" | jq -r '.full_name')
    
    echo "Checking repository: $repo_name" >&2
    
    # Fetch commits from the repository (convert PT dates to UTC for API)
    # Pacific Time is UTC-8 (or UTC-7 during DST)
    local since_utc="${SINCE_DATE}T08:00:00Z"  # 00:00 PT = 08:00 UTC
    local until_utc="${UNTIL_DATE}T08:00:00Z"  # 00:00 PT = 08:00 UTC
    
    # First, get all branches for this repository
    local branches=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/branches?per_page=100" \
        2>/dev/null || echo "[]")
    
    if [ "$branches" = "[]" ] || [ -z "$branches" ]; then
        # Fallback to just fetching from default branch if branches API fails
        local commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
            "https://api.github.com/repos/$repo_name/commits?author=$USER&since=$since_utc&until=$until_utc" \
            2>/dev/null || echo "[]")
    else
        # Fetch commits from ALL branches
        local all_commits="[]"
        local branch_count=$(echo "$branches" | jq '. | length')
        
        for i in $(seq 0 $((branch_count - 1))); do
            local branch_name=$(echo "$branches" | jq -r ".[$i].name")
            echo "  Checking branch: $branch_name" >&2
            
            local branch_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                "https://api.github.com/repos/$repo_name/commits?sha=$branch_name&author=$USER&since=$since_utc&until=$until_utc" \
                2>/dev/null || echo "[]")
            
            if [ "$branch_commits" != "[]" ] && [ -n "$branch_commits" ]; then
                # Merge commits from this branch into all_commits (avoid duplicates by SHA)
                all_commits=$(echo "$all_commits $branch_commits" | jq -s 'add | unique_by(.sha)')
            fi
        done
        
        local commits="$all_commits"
    fi
    
    if [ "$commits" != "[]" ] && [ -n "$commits" ]; then
        # For each commit, get detailed information
        local commit_count=$(echo "$commits" | jq '. | length')
        for i in $(seq 0 $((commit_count - 1))); do
            local commit=$(echo "$commits" | jq -c ".[$i]")
            local sha=$(echo "$commit" | jq -r '.sha')
            local message=$(echo "$commit" | jq -r '.commit.message')
            
            # Get commit details including files changed
            local commit_detail=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                "https://api.github.com/repos/$repo_name/commits/$sha" \
                2>/dev/null || echo "{}")
            
            if [ "$commit_detail" != "{}" ]; then
                # Create a combined JSON object
                local commit_data=$(jq -n \
                    --arg repo "$repo_name" \
                    --arg sha "$sha" \
                    --arg message "$message" \
                    --argjson files "$(echo "$commit_detail" | jq '.files // []')" \
                    --argjson stats "$(echo "$commit_detail" | jq '.stats // {}')" \
                    '{
                        repository: $repo,
                        sha: $sha,
                        message: $message,
                        files: $files,
                        stats: $stats
                    }')
                
                # Append to the commits file
                jq --argjson new_commit "$commit_data" '. += [$new_commit]' "$COMMITS_FILE" > "${COMMITS_FILE}.tmp" && mv "${COMMITS_FILE}.tmp" "$COMMITS_FILE"
            fi
        done
    fi
}

# Fetch all repositories the user has access to
page=1
while true; do
    repos=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/user/repos?per_page=100&page=$page&type=all" \
        2>/dev/null || echo "[]")
    
    if [ "$repos" = "[]" ] || [ -z "$repos" ]; then
        break
    fi
    
    # Process each repository
    local repo_count=$(echo "$repos" | jq '. | length')
    for i in $(seq 0 $((repo_count - 1))); do
        local repo=$(echo "$repos" | jq -c ".[$i]")
        fetch_repo_commits "$repo"
    done
    
    # Check if there are more pages
    if [ $(echo "$repos" | jq '. | length') -lt 100 ]; then
        break
    fi
    
    page=$((page + 1))
done

# Also check organizations
orgs=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user/orgs" \
    2>/dev/null || echo "[]")

if [ "$orgs" != "[]" ] && [ -n "$orgs" ]; then
    echo "$orgs" | jq -r '.[].login' | while read -r org; do
        echo "Checking organization: $org"
        
        page=1
        while true; do
            org_repos=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                "https://api.github.com/orgs/$org/repos?per_page=100&page=$page" \
                2>/dev/null || echo "[]")
            
            if [ "$org_repos" = "[]" ] || [ -z "$org_repos" ]; then
                break
            fi
            
            local org_repo_count=$(echo "$org_repos" | jq '. | length')
            for i in $(seq 0 $((org_repo_count - 1))); do
                local repo=$(echo "$org_repos" | jq -c ".[$i]")
                fetch_repo_commits "$repo"
            done
            
            if [ $(echo "$org_repos" | jq '. | length') -lt 100 ]; then
                break
            fi
            
            page=$((page + 1))
        done
    done
fi

# Output the commits data
if [ -f "$COMMITS_FILE" ]; then
    cat "$COMMITS_FILE"
else
    echo "[]" # Return empty array if no commits file
fi