#!/bin/bash
# Script to fetch commits from all repositories

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Set specific username for filtering
CURRENT_USER="ethank2222"

# Fetch repositories from GitHub API
fetch_repositories() {
    echo "🔍 Fetching repositories from GitHub API..."
    
    local REPOS_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/user/repos?sort=updated&per_page=200&affiliation=owner,collaborator,organization_member" || echo '[]')
    
    # Check API response for errors
    if echo "$REPOS_RESPONSE" | jq -e 'has("message")' >/dev/null 2>&1; then
        local ERROR_MSG=$(echo "$REPOS_RESPONSE" | jq -r '.message // "Unknown error"' 2>/dev/null)
        echo "❌ GitHub API Error: $ERROR_MSG"
        echo "🔍 This might be due to:"
        echo "   - Invalid GITHUB_TOKEN"
        echo "   - Rate limiting"
        echo "   - Insufficient permissions"
        return 1
    fi
    
    # Check if we got a valid response
    if [ "$REPOS_RESPONSE" = "[]" ]; then
        echo "❌ Error: No repositories returned from GitHub API"
        echo "This could be due to:"
        echo "- Invalid GITHUB_TOKEN"
        echo "- No repository access"
        echo "- API rate limiting"
        return 1
    fi
    
    # Extract repository names
    local REPOS=$(echo "$REPOS_RESPONSE" | jq -r '.[].full_name' 2>/dev/null || echo "")
    
    # Debug: Show what we found
    echo "📋 Raw repository response count: $(echo "$REPOS_RESPONSE" | jq 'length' 2>/dev/null || echo "0")"
    echo "📋 Extracted repository names count: $(echo "$REPOS" | wc -l)"
    
    # Show first few repositories for debugging
    echo "📋 First 5 repositories found:"
    echo "$REPOS" | head -5 | while read -r repo; do
        if [ -n "$repo" ]; then
            echo "  - $repo"
        fi
    done
    
    local TOTAL_REPO_COUNT=$(echo "$REPOS" | wc -l)
    echo "📋 Total repositories to process: $TOTAL_REPO_COUNT"
    
    if [ "$TOTAL_REPO_COUNT" -eq 0 ]; then
        echo "❌ Error: No repositories found to process"
        return 1
    fi
    
    echo "$REPOS"
}

# Fetch commits from a single repository
fetch_repo_commits() {
    local repo="$1"
    local start_iso="$2"
    local end_iso="$3"
    
    echo "🔍 Checking repository: $repo"
    
    # Get all branches for this repository
    echo "  🌿 Fetching all branches for $repo..."
    local BRANCHES_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$repo/branches?per_page=100" || echo '[]')
    
    # Extract branch names
    local BRANCHES=$(echo "$BRANCHES_RESPONSE" | jq -r '.[].name' 2>/dev/null || echo "")
    local BRANCH_COUNT=$(echo "$BRANCHES" | wc -l)
    echo "  📋 Found $BRANCH_COUNT branches in $repo"
    
    # Initialize repository commits array
    local REPO_ALL_COMMITS_ARRAY="[]"
    local REPO_COMMIT_COUNT=0
    
    # Get commits from each branch
    if [ -n "$BRANCHES" ]; then
        while IFS= read -r branch; do
            if [ -n "$branch" ]; then
                echo "  🔍 Checking branch: $branch"
                
                # Get commits for this specific branch
                local BRANCH_COMMITS_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                    -H "Accept: application/vnd.github.v3+json" \
                    "https://api.github.com/repos/$repo/commits?since=$start_iso&until=$end_iso&per_page=100&sha=$branch" || echo '[]')
                
                # Count commits in this branch
                local BRANCH_COMMIT_COUNT=$(echo "$BRANCH_COMMITS_RESPONSE" | jq 'length' 2>/dev/null || echo "0")
                echo "    📝 Found $BRANCH_COMMIT_COUNT commits in branch $branch"
                
                # Merge branch commits into repository array (avoid duplicates by SHA)
                if [ "$BRANCH_COMMIT_COUNT" -gt 0 ]; then
                    REPO_ALL_COMMITS_ARRAY=$(echo "$REPO_ALL_COMMITS_ARRAY" | jq --argjson branch_commits "$BRANCH_COMMITS_RESPONSE" '. + $branch_commits | unique_by(.sha)' 2>/dev/null || echo "$REPO_ALL_COMMITS_ARRAY")
                    REPO_COMMIT_COUNT=$(echo "$REPO_ALL_COMMITS_ARRAY" | jq 'length' 2>/dev/null || echo "0")
                fi
            fi
        done <<< "$BRANCHES"
    fi
    
    # Check if we found any commits
    if [ "$REPO_COMMIT_COUNT" -eq 0 ]; then
        echo "  ⚠️ No commits found in any branch for $repo"
    else
        echo "  ✅ Found $REPO_COMMIT_COUNT total commits across all branches"
    fi
    
    # Debug: Show all commits found (before filtering)
    local TOTAL_COMMITS_IN_REPO=$(echo "$REPO_ALL_COMMITS_ARRAY" | jq 'length' 2>/dev/null || echo "0")
    echo "  📊 Total commits in repo: $TOTAL_COMMITS_IN_REPO"
    
    # Show first few commits for debugging
    echo "  📋 First 3 commits (all authors):"
    echo "$REPO_ALL_COMMITS_ARRAY" | jq -r '.[0:3] | .[] | "  - \(.sha[0:7]) by \(.author.login // .commit.author.name): \(.commit.message | split("\n")[0] | @sh)"' 2>/dev/null | sed "s/'//g" || echo "  No commits found"
    
    # Extract commit information, filtering to only specific user's commits
    local REPO_COMMITS=$(echo "$REPO_ALL_COMMITS_ARRAY" | jq -r --arg user "$CURRENT_USER" '.[] | select(.author.login == $user or .committer.login == $user) | "• \(.sha[0:7]) [\(.commit.author.date | fromdateiso8601 | strftime("%m/%d"))]: \(.commit.message | split("\n")[0] | @sh)"' 2>/dev/null | sed "s/'//g" || echo "")
    
    # Count only user's commits
    local USER_COMMIT_COUNT=$(echo "$REPO_ALL_COMMITS_ARRAY" | jq --arg user "$CURRENT_USER" '[.[] | select(.author.login == $user or .committer.login == $user)] | length' 2>/dev/null || echo "0")
    
    echo "  📝 Found $USER_COMMIT_COUNT of your commits in $repo"
    
    # Return formatted result
    if [ -n "$REPO_COMMITS" ] && [ "$USER_COMMIT_COUNT" -gt 0 ]; then
        echo "RESULT:$USER_COMMIT_COUNT:$REPO_COMMITS"
    else
        echo "RESULT:0:"
    fi
}

# Main function to collect all commits
collect_all_commits() {
    local REPOS="$1"
    local ALL_COMMITS=""
    local TOTAL_COMMITS=0
    local REPO_COUNT=0
    local REPO_INDEX=0
    
    echo "🔄 Starting repository iteration..."
    
    while IFS= read -r repo; do
        if [ -n "$repo" ]; then
            REPO_INDEX=$((REPO_INDEX + 1))
            
            # Fetch commits for this repository
            local RESULT=$(fetch_repo_commits "$repo" "$START_ISO" "$END_ISO")
            
            # Parse the result
            local REPO_COMMIT_COUNT=$(echo "$RESULT" | grep "^RESULT:" | cut -d: -f2)
            local REPO_COMMITS=$(echo "$RESULT" | grep "^RESULT:" | cut -d: -f3-)
            
            # Add repository header and commits
            if [ -n "$REPO_COMMITS" ] && [ "$REPO_COMMIT_COUNT" -gt 0 ]; then
                if [ -n "$ALL_COMMITS" ]; then
                    ALL_COMMITS="${ALL_COMMITS}

📁 **${repo}** (${REPO_COMMIT_COUNT} commits):
${REPO_COMMITS}"
                else
                    ALL_COMMITS="📁 **${repo}** (${REPO_COMMIT_COUNT} commits):
${REPO_COMMITS}"
                fi
                TOTAL_COMMITS=$((TOTAL_COMMITS + REPO_COMMIT_COUNT))
            else
                if [ -n "$ALL_COMMITS" ]; then
                    ALL_COMMITS="${ALL_COMMITS}

📁 **${repo}** (0 commits):
• No commits in this period"
                else
                    ALL_COMMITS="📁 **${repo}** (0 commits):
• No commits in this period"
                fi
            fi
            
            REPO_COUNT=$((REPO_COUNT + 1))
        fi
    done <<< "$REPOS"
    
    echo "✅ Repository iteration complete. Processed $REPO_INDEX repositories."
    echo "📊 Total: $TOTAL_COMMITS commits across $REPO_COUNT repositories"
    
    # Export results
    export COMMITS="$ALL_COMMITS"
    export COMMIT_COUNT=$TOTAL_COMMITS
    export REPO_COUNT
}

# Main execution
main() {
    # Get time window
    get_time_window
    
    # Fetch repositories
    REPOS=$(fetch_repositories)
    if [ $? -ne 0 ] || [ -z "$REPOS" ]; then
        echo "⚠️ Could not fetch repositories. Falling back to current repo only."
        COMMITS=$(git log --since="$START" --until="$END" \
            --pretty=format:"• %h by %an: %s" \
            --no-merges || true)
        COMMIT_COUNT=$(git log --since="$START" --until="$END" \
            --pretty=format:"%h" --no-merges | wc -l || echo "0")
        REPO_COUNT=1
    else
        echo "📚 Found $(echo "$REPOS" | wc -l) repositories to check"
        collect_all_commits "$REPOS"
    fi
    
    # Check if we found any commits
    if [ -z "$COMMITS" ] || [ "$COMMIT_COUNT" -eq 0 ]; then
        echo "ℹ️ No commits found for previous workday."
        COMMITS="No commits found in the specified period."
        COMMIT_COUNT=0
    else
        echo "Found $COMMIT_COUNT commits to summarize"
    fi
    
    # Save results to file for next script
    cat > /tmp/commits_data.json <<EOF
{
    "commits": $(echo "$COMMITS" | jq -Rs .),
    "commit_count": $COMMIT_COUNT,
    "repo_count": ${REPO_COUNT:-1},
    "start": "$START",
    "end": "$END",
    "today": $TODAY
}
EOF
    
    echo "✅ Commit data saved to /tmp/commits_data.json"
}

# Run main function
main