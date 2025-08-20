#!/bin/bash
# Common functions and variables used across all scripts

set -euo pipefail

# Set timezone to Pacific
export TZ="America/Los_Angeles"

# Initialize security masks
init_security() {
    echo "::add-mask::sk-"
    echo "::add-mask::api-"
    echo "::add-mask::key-"
    echo "::add-mask::token-"
    echo "::add-mask::bearer"
    echo "::add-mask::webhook"
    
    # Mask environment variables if they exist
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        echo "::add-mask::${OPENAI_API_KEY}"
    fi
    if [ -n "${WEBHOOK_URL:-}" ]; then
        echo "::add-mask::${WEBHOOK_URL}"
    fi
    
    echo "✅ Security masks initialized"
}

# Validate OpenAI API key
validate_api_key() {
    if [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "❌ Error: OPENAI_API_KEY secret is not configured"
        echo "Please add your OpenAI API key to repository secrets:"
        echo "1. Go to Settings → Secrets and variables → Actions"
        echo "2. Click 'New repository secret'"
        echo "3. Name: OPENAI_API_KEY"
        echo "4. Value: Your OpenAI API key"
        return 1
    fi
    
    # Security check: Validate key format without exposing it
    KEY_LENGTH=${#OPENAI_API_KEY}
    if [ $KEY_LENGTH -lt 10 ]; then
        echo "❌ Error: OPENAI_API_KEY appears to be invalid (too short)"
        return 1
    fi
    echo "✅ API key validated (length: $KEY_LENGTH characters)"
    return 0
}

# Calculate time window for commits
get_time_window() {
    TODAY=$(date +%u)  # weekday number (1=Mon ... 7=Sun)
    
    # Get current Pacific time for reference
    PACIFIC_NOW=$(TZ="America/Los_Angeles" date +"%Y-%m-%d %H:%M:%S")
    echo "📅 Current Pacific Time: $PACIFIC_NOW"
    
    # Calculate start and end dates in Pacific time
    # Handle Monday (include weekend commits) - Extended time window for better coverage
    if [ "$TODAY" -eq 1 ]; then
        # Monday: Get commits from Friday 00:00 PT to Sunday 23:59:59 PT
        START_PACIFIC=$(TZ="America/Los_Angeles" date -d "last Friday 00:00:00" +"%Y-%m-%d %H:%M:%S")
        END_PACIFIC=$(TZ="America/Los_Angeles" date -d "yesterday 23:59:59" +"%Y-%m-%d %H:%M:%S")
    else
        # Other days: Get commits from yesterday 00:00 PT to yesterday 23:59:59 PT  
        START_PACIFIC=$(TZ="America/Los_Angeles" date -d "yesterday 00:00:00" +"%Y-%m-%d %H:%M:%S")
        END_PACIFIC=$(TZ="America/Los_Angeles" date -d "yesterday 23:59:59" +"%Y-%m-%d %H:%M:%S")
    fi
    
    # Convert Pacific times to UTC for GitHub API (GitHub expects UTC in ISO format)
    START_ISO=$(TZ="America/Los_Angeles" date -d "$START_PACIFIC" -u +"%Y-%m-%dT%H:%M:%SZ")
    END_ISO=$(TZ="America/Los_Angeles" date -d "$END_PACIFIC" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "📅 Collecting commits for Pacific Time window:"
    echo "  Start: $START_PACIFIC PT"
    echo "  End: $END_PACIFIC PT"
    echo "🔍 GitHub API time window (UTC):"
    echo "  Start: $START_ISO"
    echo "  End: $END_ISO"
    
    # Export for use in other scripts
    export START="$START_PACIFIC"
    export END="$END_PACIFIC" 
    export START_ISO END_ISO TODAY
}

# Sanitize text to remove sensitive data
sanitize_output() {
    local text="$1"
    echo "$text" | \
        sed 's/sk-[a-zA-Z0-9_-]\{20,\}/**REDACTED**/g' | \
        sed 's/\b[a-fA-F0-9]\{32,\}\b/**KEY**/g'
}