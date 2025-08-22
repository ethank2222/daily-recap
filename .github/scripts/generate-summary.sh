#!/bin/bash

# Process commits and generate ChatGPT summary

set -euo pipefail

# Read commits data from stdin or file
if [ -n "$1" ]; then
    COMMITS_DATA=$(cat "$1")
else
    COMMITS_DATA=$(cat)
fi

# Validate input JSON
if ! echo "$COMMITS_DATA" | jq . >/dev/null 2>&1; then
    echo "Error: Invalid JSON input" >&2
    echo '{"summary": "Failed to parse commit data", "commit_count": 0, "repo_count": 0, "bullet_points": ""}'
    exit 0
fi

# Check if there are any commits
COMMIT_COUNT=$(echo "$COMMITS_DATA" | jq '. | length' 2>/dev/null || echo "0")

if [ "$COMMIT_COUNT" -eq 0 ] || [ "$COMMIT_COUNT" = "null" ]; then
    echo "No commits found for the specified period" >&2
    # Return empty summary
    echo '{"summary": "No development activity recorded for the previous workday.", "commit_count": 0, "repo_count": 0, "bullet_points": ""}'
    exit 0
fi

echo "Processing $COMMIT_COUNT commits for summary generation..." >&2

# Group commits by repository
REPOS=$(echo "$COMMITS_DATA" | jq -r '[.[].repository] | unique | .[]')
REPO_COUNT=$(echo "$COMMITS_DATA" | jq '[.[].repository] | unique | length')

echo "Found $COMMIT_COUNT commits across $REPO_COUNT repositories" >&2

# Prepare the data for ChatGPT
CHATGPT_PROMPT="Analyze the following git commits from the previous workday and create a concise bullet-point summary in markdown format. Focus on the actual changes made, not just listing commit messages. Group related changes together when possible. Order the bullet points by importance (most significant changes first). For bug fixes, mention the specific files affected.

Guidelines:
- Be specific but concise
- Use format like: '- Implemented functionality to allow users to input timecard data'
- For bug fixes: '- Fixed bugs in FILENAME related to [issue]'
- Group similar changes together
- Focus on what was accomplished, not how

Commits data:"

# Process each repository
REPO_SUMMARIES=""
while IFS= read -r repo; do
    REPO_COMMITS=$(echo "$COMMITS_DATA" | jq -c "[.[] | select(.repository == \"$repo\")]")
    
    # Extract relevant information for this repo
    REPO_INFO="Repository: $repo\n"
    
    COMMIT_COUNT_REPO=$(echo "$REPO_COMMITS" | jq '. | length')
    for i in $(seq 0 $((COMMIT_COUNT_REPO - 1))); do
        commit=$(echo "$REPO_COMMITS" | jq -c ".[$i]")
        MESSAGE=$(echo "$commit" | jq -r '.message // ""')
        FILES=$(echo "$commit" | jq -r '.files[].filename // ""' | paste -sd ", " -)
        ADDITIONS=$(echo "$commit" | jq -r '.stats.additions // 0')
        DELETIONS=$(echo "$commit" | jq -r '.stats.deletions // 0')
        
        # Clean the message to prevent issues
        MESSAGE=$(echo "$MESSAGE" | tr -d '\r' | sed 's/"/\\"/g')
        
        REPO_INFO="${REPO_INFO}Commit: $MESSAGE\nFiles changed: $FILES\nLines: +$ADDITIONS -$DELETIONS\n\n"
    done
    
    REPO_SUMMARIES="${REPO_SUMMARIES}${REPO_INFO}\n"
done <<< "$REPOS"

# Create the full prompt
FULL_PROMPT="${CHATGPT_PROMPT}\n\n${REPO_SUMMARIES}"

# Call ChatGPT API
echo "Calling ChatGPT API for summary generation..." >&2
RESPONSE=$(curl -s --max-time 60 -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg prompt "$FULL_PROMPT" \
        '{
            model: "gpt-4o-mini",
            messages: [
                {
                    role: "system",
                    content: "You are a technical assistant that summarizes git commits into clear, concise bullet points for daily development reports."
                },
                {
                    role: "user",
                    content: $prompt
                }
            ],
            temperature: 0.3,
            max_tokens: 1000
        }')" \
    2>/dev/null || echo '{"error": "Failed to call ChatGPT API"}')

echo "ChatGPT API response received" >&2

# Check for errors
if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "Warning: ChatGPT API error, using fallback summary" >&2
    
    # Fallback to basic summary
    SUMMARY="Development activity summary ($COMMIT_COUNT commits across $REPO_COUNT repositories)"
    BULLET_POINTS=$(echo "$COMMITS_DATA" | jq -r '[.[] | "- " + .repository + ": " + (.message // "")] | unique | .[]' 2>/dev/null || echo "")
else
    # Extract the summary from ChatGPT response
    SUMMARY=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "Summary generation failed"')
    
    # The summary is already in bullet points format from ChatGPT
    BULLET_POINTS="$SUMMARY"
fi

# Create the final JSON output
jq -n \
    --arg summary "$SUMMARY" \
    --arg bullet_points "$BULLET_POINTS" \
    --argjson commit_count "$COMMIT_COUNT" \
    --argjson repo_count "$REPO_COUNT" \
    '{
        summary: $summary,
        bullet_points: $bullet_points,
        commit_count: $commit_count,
        repo_count: $repo_count
    }'