#!/bin/bash
# Script to generate AI summary using OpenAI API

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Load commit data
load_commit_data() {
    if [ ! -f /tmp/commits_data.json ]; then
        echo "❌ Error: Commit data file not found"
        return 1
    fi
    
    # Parse JSON data
    COMMITS=$(jq -r '.commits' /tmp/commits_data.json)
    COMMIT_COUNT=$(jq -r '.commit_count' /tmp/commits_data.json)
    REPO_COUNT=$(jq -r '.repo_count' /tmp/commits_data.json)
    START=$(jq -r '.start' /tmp/commits_data.json)
    END=$(jq -r '.end' /tmp/commits_data.json)
    TODAY=$(jq -r '.today' /tmp/commits_data.json)
    
    echo "📝 Loaded commit data: $COMMIT_COUNT commits across $REPO_COUNT repositories"
}

# Generate OpenAI API request
create_api_request() {
    local commits="$1"
    local count="$2"
    local start="$3"
    local end="$4"
    
    if [ "$count" -eq 0 ]; then
        # No commits found - create a simple message
        jq -n \
            --arg start "$start" \
            --arg end "$end" \
            '{
                model: "gpt-4o-mini",
                max_tokens: 100,
                temperature: 0.3,
                messages: [{
                    role: "user",
                    content: ($start + " to " + $end + ": No commits found. Return: 📁 No repositories with commits in this period")
                }]
            }'
    else
        # Commits found - analyze them
        jq -n \
            --arg commits "$commits" \
            --arg start "$start" \
            --arg end "$end" \
            --arg count "$count" \
            '{
                model: "gpt-4o-mini",
                max_tokens: 500,
                temperature: 0.3,
                messages: [{
                    role: "user",
                    content: ("Analyze these " + $count + " git commits and create a specific, detailed summary of what was done.\n\nRepository Activity:\n" + $commits + "\n\nCRITICAL INSTRUCTIONS:\n1. BE SPECIFIC - Name the actual features, endpoints, functions, or components\n2. NO DUPLICATES - Combine similar commits into one bullet point\n3. EXTRACT DETAILS - Look at file names and commit messages to infer specific functionality\n\nEXAMPLES OF GOOD DESCRIPTIONS:\n• Implemented OAuth2 authentication for Google and GitHub providers\n• Added connection pooling for PostgreSQL with 50 connection limit\n• Built WebSocket notification system for order status updates\n• Implemented rate limiting at 100 requests/minute for /api endpoints\n• Enhanced validation for email (RFC 5322), phone (E.164), and ZIP codes\n• Fixed payment gateway timeout issue in Stripe integration\n• Added Winston logging with Datadog integration for error tracking\n\nEXAMPLES OF BAD DESCRIPTIONS:\n• Updated authentication (too vague)\n• Integrated additional features (not specific)\n• Modified configuration files (doesn'"'"'t say what)\n• Fixed bugs (which bugs?)\n• Performed linting (if mentioned once, don'"'"'t repeat)\n• Made improvements (too generic)\n\nDEDUPLICATION RULES:\n- If multiple commits do the same thing (e.g., '"'"'lint fixes'"'"', '"'"'formatting'"'"'), mention it ONCE\n- Group related commits (e.g., '"'"'Added login, logout, and password reset endpoints'"'"')\n- If you see '"'"'Update X'"'"' and '"'"'Fix X'"'"' for same feature, combine them\n\nREQUIRED FORMAT:\n📁 Repo Name (X commits):\n• Specific thing that was implemented with details\n• Another specific feature or fix\n\n📁 Another Repo (Y commits):\n• Detailed description of what was built\n\nREMEMBER:\n- Be specific about WHAT was implemented (name the feature/function/endpoint)\n- Each bullet point on its own line\n- No duplicate or near-duplicate bullet points\n- Combine related work into single bullets when appropriate\n\nGenerate the summary:")
                }]
            }'
    fi
}

# Call OpenAI API with retry logic
call_openai_api() {
    local request_body="$1"
    local max_retries=3
    local retry_delay=2
    
    for i in $(seq 1 $max_retries); do
        echo "Calling OpenAI API (attempt $i/$max_retries)..."
        
        # Make API call
        local response=$(curl -s -S --max-time 30 \
            https://api.openai.com/v1/chat/completions \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$request_body" 2>/dev/null || echo '{"error": "curl failed"}')
        
        # Check for rate limit
        if echo "$response" | grep -q "rate_limit\|quota_exceeded" 2>/dev/null; then
            echo "⚠️ Rate limited or quota exceeded. Waiting ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
            continue
        fi
        
        # Check for authentication errors
        if echo "$response" | grep -q "invalid_api_key\|authentication" 2>/dev/null; then
            echo "❌ Authentication failed. Please check your OPENAI_API_KEY secret."
            return 1
        fi
        
        # Extract summary from response
        local summary=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        
        if [ -n "$summary" ]; then
            echo "✅ Successfully generated summary"
            echo "$summary"
            return 0
        fi
        
        # Extract error message
        local error=$(echo "$response" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null | \
            sed 's/sk-[a-zA-Z0-9]*/**REDACTED**/g' | \
            sed 's/[a-zA-Z0-9]{32,}/**KEY**/g')
        echo "⚠️ API call failed: ${error:0:100}"
        
        if [ $i -lt $max_retries ]; then
            echo "Retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
    done
    
    return 1
}

# Format summary for output
format_summary() {
    local summary="$1"
    
    echo "🔧 Post-processing summary for proper markdown formatting..."
    
    # Convert any dash (-) to bullet points (•) if they're not already
    summary=$(echo "$summary" | sed 's/^[[:space:]]*-[[:space:]]/• /g')
    
    # Ensure bullet points are properly formatted with line breaks
    summary=$(echo "$summary" | sed 's/^[[:space:]]*•[[:space:]]*/• /g')
    
    # Ensure each repository header is on its own line with proper spacing
    summary=$(echo "$summary" | sed 's/📁/\n\n📁/g' | sed 's/^\n\n//')
    
    echo "✅ Summary formatting complete"
    echo "$summary"
}

# Generate fallback summary
generate_fallback_summary() {
    local commit_count="$1"
    local repo_count="$2"
    local today="$3"
    
    echo "⚠️ Using fallback summary"
    
    local summary
    if [ "$commit_count" -eq 0 ]; then
        if [ "$today" -eq 1 ]; then
            summary="📁 No repositories with commits over the weekend"
        else
            summary="📁 No repositories with commits yesterday"
        fi
    else
        if [ "$today" -eq 1 ]; then
            summary="📁 Completed $commit_count commits across $repo_count repositories over the weekend"
        else
            summary="📁 Completed $commit_count commits across $repo_count repositories yesterday"
        fi
    fi
    
    format_summary "$summary"
}

# Main function
main() {
    # Validate API key
    validate_api_key || exit 1
    
    # Load commit data
    load_commit_data || exit 1
    
    echo "📝 Prepared API request for $COMMIT_COUNT commits"
    
    # Create API request
    REQUEST_BODY=$(create_api_request "$COMMITS" "$COMMIT_COUNT" "$START" "$END")
    
    # Call OpenAI API
    SUMMARY=$(call_openai_api "$REQUEST_BODY")
    
    # Use fallback if API fails
    if [ -z "$SUMMARY" ]; then
        SUMMARY=$(generate_fallback_summary "$COMMIT_COUNT" "${REPO_COUNT:-1}" "$TODAY")
    else
        SUMMARY=$(format_summary "$SUMMARY")
    fi
    
    # Final sanitization
    SUMMARY=$(sanitize_output "$SUMMARY")
    
    # Save summary to file
    cat > /tmp/summary_data.json <<EOF
{
    "summary": $(echo "$SUMMARY" | jq -Rs .),
    "commit_count": $COMMIT_COUNT,
    "repo_count": ${REPO_COUNT:-1},
    "today": $TODAY,
    "skip_webhook": false
}
EOF
    
    echo "✅ Summary saved to /tmp/summary_data.json"
}

# Run main function
main