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
    local TODAY=$(date +%u)  # weekday number (1=Mon ... 7=Sun)
    
    # Handle Monday (include weekend commits) - Extended time window for better coverage
    if [ "$TODAY" -eq 1 ]; then
        START=$(date -d "7 days ago 00:00" +"%Y-%m-%d %H:%M:%S")
    else
        START=$(date -d "3 days ago 00:00" +"%Y-%m-%d %H:%M:%S")
    fi
    
    END=$(date -d "tomorrow 00:00" +"%Y-%m-%d %H:%M:%S")
    
    # Convert to ISO format for GitHub API
    START_ISO=$(TZ="America/Los_Angeles" date -d "$START" +"%Y-%m-%dT%H:%M:%SZ")
    END_ISO=$(TZ="America/Los_Angeles" date -d "$END" +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "📅 Collecting commits between $START and $END (Pacific Time)"
    echo "🔍 Debug: Time window for GitHub API:"
    echo "  Start (UTC): $START_ISO"
    echo "  End (UTC): $END_ISO"
    
    # Export for use in other scripts
    export START START_ISO END END_ISO TODAY
}

# Sanitize text to remove sensitive data
sanitize_output() {
    local text="$1"
    echo "$text" | \
        sed 's/sk-[a-zA-Z0-9_-]\{20,\}/**REDACTED**/g' | \
        sed 's/\b[a-fA-F0-9]\{32,\}\b/**KEY**/g'
}