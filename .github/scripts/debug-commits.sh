#!/bin/bash

# Debug script to test commit fetching

set -euo pipefail

echo "========================================="
echo "Commit Fetching Debug"
echo "========================================="

# Set timezone to Pacific Time
export TZ='America/Los_Angeles'

# Check environment variables
echo "Environment variables:"
echo "- TOKEN_GITHUB: ${TOKEN_GITHUB:0:10}..."
echo "- AUTHOR_ACCOUNT: ${AUTHOR_ACCOUNT:-NOT SET}"
echo "- TZ: $TZ"

# Test authentication
echo ""
echo "Testing GitHub authentication..."
AUTH_USER=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user" | jq -r '.login' 2>/dev/null || echo "")

if [ -n "$AUTH_USER" ] && [ "$AUTH_USER" != "null" ]; then
    echo "✓ Authenticated as: $AUTH_USER"
else
    echo "✗ Authentication failed"
    exit 1
fi

# Test author account
echo ""
echo "Testing author account: $AUTHOR_ACCOUNT"
AUTHOR_INFO=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/users/$AUTHOR_ACCOUNT" 2>/dev/null || echo '{"error": "Failed"}')

if echo "$AUTHOR_INFO" | jq -e '.error' >/dev/null 2>&1; then
    echo "✗ Cannot access author account"
    echo "Response: $AUTHOR_INFO"
    exit 1
else
    AUTHOR_NAME=$(echo "$AUTHOR_INFO" | jq -r '.name // .login' 2>/dev/null || echo "$AUTHOR_ACCOUNT")
    echo "✓ Author account: $AUTHOR_NAME ($AUTHOR_ACCOUNT)"
fi

# Test date calculation
echo ""
echo "Testing date calculation..."
DAY_OF_WEEK=$(date +%u)
echo "Day of week: $DAY_OF_WEEK"

if [ "$DAY_OF_WEEK" -eq 1 ]; then
    SINCE_DATE=$(date -d "last Friday" +%Y-%m-%d 2>/dev/null || date -v-3d +%Y-%m-%d 2>/dev/null || echo "FAILED")
    UNTIL_DATE=$(date -d "last Saturday" +%Y-%m-%d 2>/dev/null || date -v-2d +%Y-%m-%d 2>/dev/null || echo "FAILED")
else
    SINCE_DATE=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "FAILED")
    UNTIL_DATE=$(date +%Y-%m-%d)
fi

echo "Since date: $SINCE_DATE"
echo "Until date: $UNTIL_DATE"

# Test UTC conversion
SINCE_UTC="${SINCE_DATE}T07:00:00Z"
UNTIL_UTC="${UNTIL_DATE}T08:59:59Z"
echo "Since UTC: $SINCE_UTC"
echo "Until UTC: $UNTIL_UTC"

# Test repository access
echo ""
echo "Testing repository access..."
REPOS=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user/repos?per_page=5" \
    2>/dev/null || echo "[]")

REPO_COUNT=$(echo "$REPOS" | jq '. | length' 2>/dev/null || echo "0")
echo "Found $REPO_COUNT repositories"

if [ "$REPO_COUNT" -gt 0 ]; then
    echo "Sample repositories:"
    echo "$REPOS" | jq -r '.[0:3] | .[] | "  - \(.full_name)"' 2>/dev/null || echo "  Unable to parse repositories"
    
    # Test commit search on first repository
    FIRST_REPO=$(echo "$REPOS" | jq -r '.[0].full_name' 2>/dev/null || echo "")
    if [ -n "$FIRST_REPO" ] && [ "$FIRST_REPO" != "null" ]; then
        echo ""
        echo "Testing commit search on: $FIRST_REPO"
        
        # Search for commits by author
        COMMITS=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
            "https://api.github.com/repos/$FIRST_REPO/commits?author=$AUTHOR_ACCOUNT&since=$SINCE_UTC&until=$UNTIL_UTC&per_page=5" \
            2>/dev/null || echo "[]")
        
        COMMIT_COUNT=$(echo "$COMMITS" | jq '. | length' 2>/dev/null || echo "0")
        echo "Found $COMMIT_COUNT commits by $AUTHOR_ACCOUNT in date range"
        
        if [ "$COMMIT_COUNT" -gt 0 ]; then
            echo "Sample commits:"
            echo "$COMMITS" | jq -r '.[0:3] | .[] | "  - \(.sha[0:8]): \(.commit.message | .[0:50])..."' 2>/dev/null || echo "  Unable to parse commits"
        else
            # Try broader search
            echo "No commits found in date range, trying broader search..."
            BROADER_COMMITS=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
                "https://api.github.com/repos/$FIRST_REPO/commits?author=$AUTHOR_ACCOUNT&per_page=5" \
                2>/dev/null || echo "[]")
            
            BROADER_COUNT=$(echo "$BROADER_COMMITS" | jq '. | length' 2>/dev/null || echo "0")
            echo "Found $BROADER_COUNT commits by $AUTHOR_ACCOUNT (any date)"
            
            if [ "$BROADER_COUNT" -gt 0 ]; then
                echo "Most recent commit:"
                echo "$BROADER_COMMITS" | jq -r '.[0] | "  - \(.sha[0:8]): \(.commit.message | .[0:50])... (\(.commit.author.date))"' 2>/dev/null || echo "  Unable to parse commit"
            fi
        fi
    fi
fi

echo ""
echo "========================================="
echo "Debug completed"
echo "========================================="
