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

echo "Fetching commits from $SINCE_DATE to $UNTIL_DATE (Pacific Time) across ALL branches" >&2

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

echo "Fetching commits for user: $USER from all branches" >&2

# Function to safely merge JSON arrays
safe_merge_commits() {
    local existing="$1"
    local new_commits="$2"
    
    if ! echo "$new_commits" | jq . >/dev/null 2>&1 || [ "$new_commits" = "[]" ] || [ -z "$new_commits" ]; then
        echo "$existing"
        return
    fi
    
    # Merge and deduplicate by SHA
    echo "$existing $new_commits" | jq -s 'add | unique_by(.sha)' 2>/dev/null || echo "$existing"
}

# Function to fetch commits from a repository
fetch_repo_commits() {
    local repo_url=$1
    local repo_name=$(echo "$repo_url" | jq -r '.full_name' 2>/dev/null || echo "")
    
    if [ -z "$repo_name" ] || [ "$repo_name" = "null" ]; then
        return
    fi
    
    echo "Checking repository: $repo_name" >&2
    
    # Convert PT dates to UTC for API (Pacific Time is UTC-8)
    local since_utc="${SINCE_DATE}T08:00:00Z"  # 00:00 PT = 08:00 UTC
    local until_utc="${UNTIL_DATE}T08:00:00Z"  # 00:00 PT = 08:00 UTC
    
    # Start with default branch commits
    local all_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/commits?author=$USER&since=$since_utc&until=$until_utc" \
        2>/dev/null || echo "[]")
    
    # Validate default branch commits
    if ! echo "$all_commits" | jq . >/dev/null 2>&1; then
        all_commits="[]"
    fi
    
    # Get all branches
    local branches=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/branches?per_page=100" \
        2>/dev/null || echo "[]")
    
    # Process branches if API call succeeded
    if echo "$branches" | jq . >/dev/null 2>&1 && [ "$branches" != "[]" ]; then
        local branch_count=$(echo "$branches" | jq '. | length' 2>/dev/null || echo "0")
        
        if [ "$branch_count" -gt 0 ]; then
            for i in $(seq 0 $((branch_count - 1))); do
                local branch_name=$(echo "$branches" | jq -r ".[$i].name" 2>/dev/null || echo "")
                
                if [ -n "$branch_name" ] && [ "$branch_name" != "null" ]; then
                    echo "  Checking branch: $branch_name" >&2
                    
                    local branch_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                        "https://api.github.com/repos/$repo_name/commits?sha=$branch_name&author=$USER&since=$since_utc&until=$until_utc" \
                        2>/dev/null || echo "[]")
                    
                    all_commits=$(safe_merge_commits "$all_commits" "$branch_commits")
                fi
            done
        fi
    fi
    
    # Process each commit to get detailed information
    if [ "$all_commits" != "[]" ] && [ -n "$all_commits" ]; then
        local commit_count=$(echo "$all_commits" | jq '. | length' 2>/dev/null || echo "0")
        
        if [ "$commit_count" -gt 0 ]; then
            for i in $(seq 0 $((commit_count - 1))); do
                local commit=$(echo "$all_commits" | jq -c ".[$i]" 2>/dev/null || echo "{}")
                
                if [ "$commit" != "{}" ]; then
                    local sha=$(echo "$commit" | jq -r '.sha' 2>/dev/null || echo "")
                    local message=$(echo "$commit" | jq -r '.commit.message' 2>/dev/null || echo "")
                    
                    if [ -n "$sha" ] && [ "$sha" != "null" ]; then
                        # Get commit details including files changed
                        local commit_detail=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                            "https://api.github.com/repos/$repo_name/commits/$sha" \
                            2>/dev/null || echo "{}")
                        
                        if echo "$commit_detail" | jq . >/dev/null 2>&1 && [ "$commit_detail" != "{}" ]; then
                            # Create a combined JSON object
                            local commit_data=$(jq -n \
                                --arg repo "$repo_name" \
                                --arg sha "$sha" \
                                --arg message "$message" \
                                --argjson files "$(echo "$commit_detail" | jq '.files // []' 2>/dev/null || echo '[]')" \
                                --argjson stats "$(echo "$commit_detail" | jq '.stats // {}' 2>/dev/null || echo '{}')" \
                                '{
                                    repository: $repo,
                                    sha: $sha,
                                    message: $message,
                                    files: $files,
                                    stats: $stats
                                }' 2>/dev/null || echo "{}")
                            
                            if [ "$commit_data" != "{}" ]; then
                                # Append to the commits file
                                jq --argjson new_commit "$commit_data" '. += [$new_commit]' "$COMMITS_FILE" > "${COMMITS_FILE}.tmp" 2>/dev/null && mv "${COMMITS_FILE}.tmp" "$COMMITS_FILE" || true
                            fi
                        fi
                    fi
                fi
            done
        fi
    fi
}

# Fetch all repositories the user has access to
page=1
while true; do
    repos=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/user/repos?per_page=100&page=$page&type=all" \
        2>/dev/null || echo "[]")
    
    if ! echo "$repos" | jq . >/dev/null 2>&1 || [ "$repos" = "[]" ] || [ -z "$repos" ]; then
        break
    fi
    
    # Process each repository
    local repo_count=$(echo "$repos" | jq '. | length' 2>/dev/null || echo "0")
    if [ "$repo_count" -gt 0 ]; then
        for i in $(seq 0 $((repo_count - 1))); do
            local repo=$(echo "$repos" | jq -c ".[$i]" 2>/dev/null || echo "{}")
            if [ "$repo" != "{}" ]; then
                fetch_repo_commits "$repo"
            fi
        done
    fi
    
    # Check if there are more pages
    if [ "$repo_count" -lt 100 ]; then
        break
    fi
    
    page=$((page + 1))
done

# Also check organizations
orgs=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user/orgs" \
    2>/dev/null || echo "[]")

if echo "$orgs" | jq . >/dev/null 2>&1 && [ "$orgs" != "[]" ] && [ -n "$orgs" ]; then
    echo "$orgs" | jq -r '.[].login' | while read -r org; do
        if [ -n "$org" ] && [ "$org" != "null" ]; then
            echo "Checking organization: $org" >&2
            
            page=1
            while true; do
                org_repos=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                    "https://api.github.com/orgs/$org/repos?per_page=100&page=$page" \
                    2>/dev/null || echo "[]")
                
                if ! echo "$org_repos" | jq . >/dev/null 2>&1 || [ "$org_repos" = "[]" ] || [ -z "$org_repos" ]; then
                    break
                fi
                
                local org_repo_count=$(echo "$org_repos" | jq '. | length' 2>/dev/null || echo "0")
                if [ "$org_repo_count" -gt 0 ]; then
                    for i in $(seq 0 $((org_repo_count - 1))); do
                        local repo=$(echo "$org_repos" | jq -c ".[$i]" 2>/dev/null || echo "{}")
                        if [ "$repo" != "{}" ]; then
                            fetch_repo_commits "$repo"
                        fi
                    done
                fi
                
                if [ "$org_repo_count" -lt 100 ]; then
                    break
                fi
                
                page=$((page + 1))
            done
        fi
    done
fi

# Output the commits data
if [ -f "$COMMITS_FILE" ]; then
    cat "$COMMITS_FILE"
else
    echo "[]" # Return empty array if no commits file
fi