#!/bin/bash

# Fetch commits from the previous workday across all accessible repositories

set -euo pipefail

# Set timezone to Pacific Time
export TZ='America/Los_Angeles'

# Get the date range in Pacific Time (cross-platform compatible)
get_date_range() {
    local day_of_week=$(date +%u)
    
    if [ "$day_of_week" -eq 1 ]; then
        # It's Monday, look at Friday
        if command -v gdate &> /dev/null; then
            # macOS with coreutils
            SINCE_DATE=$(gdate -d "last Friday" +%Y-%m-%d)
            UNTIL_DATE=$(gdate -d "last Saturday" +%Y-%m-%d)
        elif date --version &> /dev/null; then
            # Linux GNU date
            SINCE_DATE=$(date -d "last Friday" +%Y-%m-%d)
            UNTIL_DATE=$(date -d "last Saturday" +%Y-%m-%d)
        else
            # BSD/macOS default date
            SINCE_DATE=$(date -v-3d +%Y-%m-%d)
            UNTIL_DATE=$(date -v-2d +%Y-%m-%d)
        fi
    else
        # Look at yesterday
        if command -v gdate &> /dev/null; then
            # macOS with coreutils
            SINCE_DATE=$(gdate -d "yesterday" +%Y-%m-%d)
            UNTIL_DATE=$(gdate +%Y-%m-%d)
        elif date --version &> /dev/null; then
            # Linux GNU date
            SINCE_DATE=$(date -d "yesterday" +%Y-%m-%d)
            UNTIL_DATE=$(date +%Y-%m-%d)
        else
            # BSD/macOS default date
            SINCE_DATE=$(date -v-1d +%Y-%m-%d)
            UNTIL_DATE=$(date +%Y-%m-%d)
        fi
    fi
    
    # Validate dates
    if [ -z "$SINCE_DATE" ] || [ -z "$UNTIL_DATE" ]; then
        echo "Error: Failed to calculate date range" >&2
        return 1
    fi
    
    # Add debug information
    echo "Day of week: $day_of_week" >&2
    echo "Since date: $SINCE_DATE" >&2
    echo "Until date: $UNTIL_DATE" >&2
}

if ! get_date_range; then
    echo "Error: Date range calculation failed" >&2
    exit 1
fi

echo "Fetching commits from $SINCE_DATE to $UNTIL_DATE (Pacific Time) across ALL branches" >&2

# Temporary file to store commit data
COMMITS_FILE="/tmp/commits_data.json"
echo "[]" > "$COMMITS_FILE"

# Get the author account to search for
if [ -z "${AUTHOR_ACCOUNT:-}" ]; then
    echo "Error: AUTHOR_ACCOUNT environment variable is not set" >&2
    echo "Please set AUTHOR_ACCOUNT to the GitHub username whose commits you want to find" >&2
    exit 1
fi

# Verify the GitHub token works
echo "Authenticating with GitHub API..." >&2
AUTH_USER=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user" | jq -r '.login' || echo "")

if [ -z "$AUTH_USER" ] || [ "$AUTH_USER" = "null" ]; then
    echo "Error: Failed to authenticate with GitHub. Please check TOKEN_GITHUB" >&2
    echo "Response received: $(curl -s -H "Authorization: token $TOKEN_GITHUB" "https://api.github.com/user")" >&2
    exit 1
fi

echo "Successfully authenticated as user: $AUTH_USER" >&2
echo "Fetching commits for author: $AUTHOR_ACCOUNT from all branches" >&2

# Test basic API access
echo "Testing basic API access..." >&2
TEST_REPOS=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user/repos?per_page=1" \
    2>/dev/null || echo "[]")

if ! echo "$TEST_REPOS" | jq . >/dev/null 2>&1; then
    echo "Error: Cannot access GitHub API" >&2
    exit 1
fi

REPO_COUNT=$(echo "$TEST_REPOS" | jq '. | length' 2>/dev/null || echo "0")
echo "Found $REPO_COUNT test repositories" >&2

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

# Function to handle rate limiting
handle_rate_limit() {
    local response="$1"
    if echo "$response" | jq -e '.message' | grep -q "API rate limit exceeded" 2>/dev/null; then
        local reset_time=$(echo "$response" | jq -r '.headers.X-RateLimit-Reset // 0')
        if [ "$reset_time" -gt 0 ]; then
            local wait_time=$((reset_time - $(date +%s)))
            if [ "$wait_time" -gt 0 ]; then
                echo "Rate limit exceeded. Waiting $wait_time seconds..." >&2
                sleep "$wait_time"
                return 0
            fi
        fi
        echo "Rate limit exceeded and cannot wait. Skipping..." >&2
        return 1
    fi
    return 0
}

# Function to fetch commits from a repository
fetch_repo_commits() {
    local repo_url=$1
    local repo_name=$(echo "$repo_url" | jq -r '.full_name' 2>/dev/null || echo "")
    
    if [ -z "$repo_name" ] || [ "$repo_name" = "null" ]; then
        return
    fi
    
    echo "Checking repository: $repo_name" >&2
    
    # Convert PT dates to UTC for API - use a wider range to ensure we catch all commits
    # Pacific Time is UTC-8 in winter, UTC-7 in summer
    # Use a conservative approach that covers the entire day in PT
    local since_utc="${SINCE_DATE}T07:00:00Z"  # Start early to catch all commits
    local until_utc="${UNTIL_DATE}T08:59:59Z"  # End late to catch all commits
    
    echo "  Date range: $since_utc to $until_utc (UTC)" >&2
    echo "  Local date range: $SINCE_DATE 00:00 to $UNTIL_DATE 23:59 (Pacific Time)" >&2
    
    # Start with default branch commits (with date filter)
    echo "  Fetching commits from default branch (date filtered)..." >&2
    local all_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/commits?author=$AUTHOR_ACCOUNT&since=$since_utc&until=$until_utc" \
        2>/dev/null || echo "[]")
    
    # Also search for ALL commits by the author (no date filter) to see if there are any commits at all
    echo "  Fetching ALL commits by author (no date filter)..." >&2
    local all_author_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/commits?author=$AUTHOR_ACCOUNT&per_page=5" \
        2>/dev/null || echo "[]")
    
    local all_author_count=$(echo "$all_author_commits" | jq '. | length' 2>/dev/null || echo "0")
    if [ "$all_author_count" -gt 0 ]; then
        echo "  Found $all_author_count commits by author in this repository (any date)" >&2
        local most_recent=$(echo "$all_author_commits" | jq -r '.[0].commit.author.date' 2>/dev/null || echo "unknown")
        echo "  Most recent commit date: $most_recent" >&2
    fi
    
    # If no commits found with author filter, try without author filter to see if there are any commits
    local commit_count=$(echo "$all_commits" | jq '. | length' 2>/dev/null || echo "0")
    if [ "$commit_count" -eq 0 ]; then
        echo "  No commits found with author filter, checking for any commits in date range..." >&2
        local any_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
            "https://api.github.com/repos/$repo_name/commits?since=$since_utc&until=$until_utc&per_page=5" \
            2>/dev/null || echo "[]")
        local any_count=$(echo "$any_commits" | jq '. | length' 2>/dev/null || echo "0")
        if [ "$any_count" -gt 0 ]; then
            echo "  Found $any_count commits in date range, but none by author $AUTHOR_ACCOUNT" >&2
        else
            echo "  No commits found in date range at all" >&2
            
            # Try a broader search - look back 7 days to see if there are any recent commits
            echo "  Trying broader search (last 7 days)..." >&2
            local broader_since=$(date -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null || echo "")
            if [ -n "$broader_since" ]; then
                local broader_since_utc="${broader_since}T07:00:00Z"
                local broader_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                    "https://api.github.com/repos/$repo_name/commits?author=$AUTHOR_ACCOUNT&since=$broader_since_utc&per_page=20" \
                    2>/dev/null || echo "[]")
                local broader_count=$(echo "$broader_commits" | jq '. | length' 2>/dev/null || echo "0")
                if [ "$broader_count" -gt 0 ]; then
                    echo "  Found $broader_count commits by author in last 7 days" >&2
                    echo "  Most recent commit: $(echo "$broader_commits" | jq -r '.[0].commit.message' 2>/dev/null | head -c 50)" >&2
                fi
            fi
        fi
    fi
    
    # Validate default branch commits
    if ! echo "$all_commits" | jq . >/dev/null 2>&1; then
        echo "  Warning: Invalid JSON response from default branch API" >&2
        all_commits="[]"
    else
        local default_count=$(echo "$all_commits" | jq '. | length' 2>/dev/null || echo "0")
        echo "  Found $default_count commits on default branch" >&2
    fi
    
    # Get all branches
    echo "  Fetching branch list..." >&2
    local branches=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/repos/$repo_name/branches?per_page=100" \
        2>/dev/null || echo "[]")
    
    # Process branches if API call succeeded
    if echo "$branches" | jq . >/dev/null 2>&1 && [ "$branches" != "[]" ]; then
        local branch_count=$(echo "$branches" | jq '. | length' 2>/dev/null || echo "0")
        echo "  Found $branch_count branches to check" >&2
        
        if [ "$branch_count" -gt 0 ]; then
            for i in $(seq 0 $((branch_count - 1))); do
                local branch_name=$(echo "$branches" | jq -r ".[$i].name" 2>/dev/null || echo "")
                
                if [ -n "$branch_name" ] && [ "$branch_name" != "null" ]; then
                    echo "  Checking branch: $branch_name" >&2
                    
                    local branch_commits=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                        "https://api.github.com/repos/$repo_name/commits?sha=$branch_name&author=$AUTHOR_ACCOUNT&since=$since_utc&until=$until_utc" \
                        2>/dev/null || echo "[]")
                    
                    local branch_commit_count=$(echo "$branch_commits" | jq '. | length' 2>/dev/null || echo "0")
                    echo "    Found $branch_commit_count commits on branch $branch_name" >&2
                    
                    all_commits=$(safe_merge_commits "$all_commits" "$branch_commits")
                fi
            done
        fi
    else
        echo "  Warning: Could not fetch branch list or no branches found" >&2
    fi
    
    # Process each commit to get detailed information
    if [ "$all_commits" != "[]" ] && [ -n "$all_commits" ]; then
        local commit_count=$(echo "$all_commits" | jq '. | length' 2>/dev/null || echo "0")
        
        if [ "$commit_count" -gt 0 ]; then
            for i in $(seq 0 $((commit_count - 1))); do
                local commit=$(echo "$all_commits" | jq -c ".[$i]" 2>/dev/null || echo "{}")
                
                if [ "$commit" != "{}" ]; then
                    local sha=$(echo "$commit" | jq -r '.sha' 2>/dev/null || echo "")
                    local message=$(echo "$commit" | jq -r '.commit.message // ""' 2>/dev/null || echo "")
                    
                    # Clean and escape the message to prevent JSON parsing issues
                    message=$(echo "$message" | tr -d '\r' | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
                    
                    if [ -n "$sha" ] && [ "$sha" != "null" ] && [ -n "$message" ]; then
                        # Get commit details including files changed
                        local commit_detail=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                            "https://api.github.com/repos/$repo_name/commits/$sha" \
                            2>/dev/null || echo "{}")
                        
                        if echo "$commit_detail" | jq . >/dev/null 2>&1 && [ "$commit_detail" != "{}" ]; then
                            # Create a combined JSON object with proper escaping
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
echo "Fetching all repositories..." >&2
page=1
total_repos=0
while true; do
    repos=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
        "https://api.github.com/user/repos?per_page=100&page=$page&type=all" \
        2>/dev/null || echo "[]")
    
    if ! echo "$repos" | jq . >/dev/null 2>&1 || [ "$repos" = "[]" ] || [ -z "$repos" ]; then
        break
    fi
    
    # Process each repository
    local repo_count=$(echo "$repos" | jq '. | length' 2>/dev/null || echo "0")
    total_repos=$((total_repos + repo_count))
    echo "Processing page $page with $repo_count repositories (total: $total_repos)" >&2
    
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

echo "Completed processing $total_repos total repositories" >&2

# Also check organizations
echo "Fetching organization repositories..." >&2
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
echo "Final commit count: $(jq '. | length' "$COMMITS_FILE" 2>/dev/null || echo "0")" >&2

if [ -f "$COMMITS_FILE" ]; then
    # Ensure we output valid JSON
    if jq . "$COMMITS_FILE" >/dev/null 2>&1; then
        cat "$COMMITS_FILE"
    else
        echo "Warning: Invalid JSON in commits file, outputting empty array" >&2
        echo "[]"
    fi
else
    echo "No commits file found, outputting empty array" >&2
    echo "[]" # Return empty array if no commits file
fi