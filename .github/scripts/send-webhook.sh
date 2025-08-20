#!/bin/bash
# Script to send summary to webhook (Teams, Slack, Discord)

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Load summary data
load_summary_data() {
    if [ ! -f /tmp/summary_data.json ]; then
        echo "❌ Error: Summary data file not found"
        return 1
    fi
    
    # Parse JSON data
    SUMMARY=$(jq -r '.summary' /tmp/summary_data.json)
    COMMIT_COUNT=$(jq -r '.commit_count' /tmp/summary_data.json)
    REPO_COUNT=$(jq -r '.repo_count' /tmp/summary_data.json)
    TODAY=$(jq -r '.today' /tmp/summary_data.json)
    SKIP_WEBHOOK=$(jq -r '.skip_webhook' /tmp/summary_data.json)
    
    echo "📝 Loaded summary data: $COMMIT_COUNT commits across $REPO_COUNT repositories"
}

# Validate webhook URL
validate_webhook() {
    if [ -z "${WEBHOOK_URL:-}" ]; then
        echo "⚠️ WEBHOOK_URL secret not configured"
        echo "Summary was generated but cannot be sent."
        echo ""
        echo "To enable webhook notifications:"
        echo "1. Go to Settings → Secrets and variables → Actions"
        echo "2. Click 'New repository secret'"
        echo "3. Name: WEBHOOK_URL"
        echo "4. Value: Your Slack/Discord/Teams webhook URL"
        echo ""
        echo "Generated summary:"
        echo "$SUMMARY"
        return 1
    fi
    
    # Mask webhook URL
    echo "::add-mask::${WEBHOOK_URL}"
    
    # Detect webhook service
    if echo "$WEBHOOK_URL" | grep -q "slack.com"; then
        echo "📤 Sending summary to Slack webhook"
        WEBHOOK_TYPE="slack"
    elif echo "$WEBHOOK_URL" | grep -q "discord.com"; then
        echo "📤 Sending summary to Discord webhook"
        WEBHOOK_TYPE="discord"
    elif echo "$WEBHOOK_URL" | grep -q "office.com\|logic.azure.com\|prod-.*\.logic\.azure\.com"; then
        echo "📤 Sending summary to Teams/Power Automate webhook"
        WEBHOOK_TYPE="teams"
    else
        echo "📤 Sending summary to webhook (assuming Teams format)"
        WEBHOOK_TYPE="teams"
    fi
    
    return 0
}

# Create Teams payload that matches the required schema
create_teams_payload() {
    local summary="$1"
    local title="$2"
    local time="$3"
    local period="$4"
    local url="$5"
    
    # Format summary for Teams - clean up formatting and ensure proper escaping
    # Remove any control characters and normalize line breaks
    local formatted_summary=$(echo "$summary" | tr -d '\r' | sed 's/\t/ /g')
    # Escape for JSON properly using jq
    local escaped_summary=$(echo "$formatted_summary" | jq -Rs . 2>/dev/null || echo "\"Error formatting summary\"")
    
    echo "📋 Using schema-compliant Teams/Power Automate format"
    # Create payload that exactly matches the required schema
    jq -n \
        --arg title "$title" \
        --arg time "$time" \
        --arg repos "$REPO_COUNT" \
        --arg commits "$COMMIT_COUNT" \
        --arg period "$period" \
        --argjson summary "$escaped_summary" \
        --arg url "$url" \
        '{
            "type": "message",
            "attachments": [{
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.3",
                    "body": [
                        {
                            "type": "Container"
                        },
                        {
                            "type": "TextBlock",
                            "text": $title,
                            "size": "Large",
                            "weight": "Bolder",
                            "wrap": true
                        },
                        {
                            "type": "TextBlock",
                            "text": $time,
                            "size": "Small",
                            "wrap": true
                        },
                        {
                            "type": "FactSet",
                            "facts": [
                                {
                                    "title": "📚 Repositories",
                                    "value": $repos
                                },
                                {
                                    "title": "💻 Commits",
                                    "value": $commits
                                },
                                {
                                    "title": "📅 Period",
                                    "value": $period
                                }
                            ]
                        },
                        {
                            "type": "TextBlock",
                            "text": "**Summary**",
                            "weight": "Bolder",
                            "wrap": true
                        },
                        {
                            "type": "TextBlock",
                            "text": $summary,
                            "wrap": true
                        }
                    ]
                }
            }]
        }'
}

# Send webhook with retry logic
send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry_delay=2
    
    echo "📤 Attempting to send webhook..."
    echo "📋 Using Teams Webhook format"
    
    # Debug: Show payload size (without content)
    local payload_size=$(echo "$payload" | wc -c)
    echo "📊 Payload size: $payload_size characters"
    
    for i in $(seq 1 $max_retries); do
        # Send request and capture both status and response
        local response_file=$(mktemp)
        local http_status=$(curl -s -w "%{http_code}" \
            --max-time 15 \
            -X POST \
            -H "Content-Type: application/json; charset=utf-8" \
            -H "Accept: application/json" \
            -d "$payload" \
            "$WEBHOOK_URL" \
            -o "$response_file" 2>/dev/null || echo "000")
        
        # Read response for debugging (safely)
        local response_content=""
        if [ -f "$response_file" ]; then
            response_content=$(cat "$response_file" 2>/dev/null | head -c 500)
            rm -f "$response_file"
        fi
        
        # Check for success
        if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
            echo "✅ Webhook delivered successfully (HTTP $http_status)"
            return 0
        fi
        
        echo "⚠️ Webhook delivery failed (HTTP $http_status, attempt $i/$max_retries)"
        
        # Show sanitized error response for debugging
        if [ -n "$response_content" ] && [ "$http_status" != "000" ]; then
            echo "🔍 Response preview: $(echo "$response_content" | tr '\n' ' ' | cut -c1-200)..."
        fi
        
        # Specific error handling based on status code
        case "$http_status" in
            "400")
                echo "📋 HTTP 400: Bad Request - Payload format issue"
                ;;
            "401")
                echo "📋 HTTP 401: Unauthorized - Check webhook URL"
                ;;
            "403")
                echo "📋 HTTP 403: Forbidden - Check Teams permissions"
                ;;
            "404")
                echo "📋 HTTP 404: Not Found - Webhook URL may be expired"
                ;;
            "413")
                echo "📋 HTTP 413: Payload Too Large - Reduce summary length"
                ;;
            "429")
                echo "📋 HTTP 429: Rate Limited - Will retry with longer delay"
                retry_delay=$((retry_delay * 3))
                ;;
            "000")
                echo "📋 Network error - Connection failed"
                ;;
        esac
        
        if [ $i -lt $max_retries ]; then
            echo "Retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
    done
    
    echo "❌ Failed to send webhook after $max_retries attempts"
    echo "Please verify your WEBHOOK_URL secret is correctly configured"
    echo "Common issues:"
    echo "- Webhook URL is invalid or expired"
    echo "- Teams channel permissions are incorrect"
    echo "- Network connectivity issues"
    echo "- Payload format or size issues"
    return 1
}

# Main function
main() {
    # Load summary data
    load_summary_data || exit 1
    
    # Check if webhook should be skipped
    if [ "$SKIP_WEBHOOK" = "true" ]; then
        echo "ℹ️ Webhook sending skipped (no commits to report)"
        exit 0
    fi
    
    # Validate webhook URL
    validate_webhook || exit 0
    
    echo "📤 Sending summary to webhook..."
    
    # Prepare webhook title and metadata
    if [ "$COMMIT_COUNT" -eq 0 ]; then
        if [ "$TODAY" -eq 1 ]; then
            TITLE="🚀 **Weekend & Friday Development Summary**"
        else
            TITLE="🚀 **Yesterday's Development Summary**"
        fi
    else
        if [ "$TODAY" -eq 1 ]; then
            TITLE="🚀 **Weekend & Friday Development Summary**"
        else
            TITLE="🚀 **Yesterday's Development Summary**"
        fi
    fi
    
    CURRENT_TIME=$(date -u +"%B %d, %Y at %I:%M %p UTC")
    WORKFLOW_URL="https://github.com/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-}"
    
    if [ "$TODAY" -eq 1 ]; then
        PERIOD="Weekend & Friday"
    else
        PERIOD=$(date -d "yesterday" +"%B %d, %Y")
    fi
    
    # Create payload based on webhook type
    if [ "$WEBHOOK_TYPE" = "teams" ]; then
        PAYLOAD=$(create_teams_payload "$SUMMARY" "$TITLE" "$CURRENT_TIME" "$PERIOD" "$WORKFLOW_URL")
    else
        # For now, only Teams is fully implemented
        echo "⚠️ Only Teams webhooks are currently fully supported"
        PAYLOAD=$(create_teams_payload "$SUMMARY" "$TITLE" "$CURRENT_TIME" "$PERIOD" "$WORKFLOW_URL")
    fi
    
    # Send webhook
    if ! send_webhook "$PAYLOAD"; then
        echo "🔄 Trying with simplified message format..."
        
        # Create a simplified fallback payload that matches the required schema
        # Clean the summary text first
        local clean_summary=$(echo "$SUMMARY" | tr -d '\r' | sed 's/\t/ /g' | jq -Rs . 2>/dev/null || echo "\"Summary unavailable\"")
        
        echo "📋 Creating simplified schema-compliant payload"
        # Simplified payload that still matches the required schema
        SIMPLE_PAYLOAD=$(jq -n \
            --arg title "$TITLE" \
            --argjson summary "$clean_summary" \
            --arg commits "$COMMIT_COUNT" \
            --arg repos "$REPO_COUNT" \
            '{
                "type": "message",
                "attachments": [{
                    "contentType": "application/vnd.microsoft.card.adaptive",
                    "content": {
                        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                        "type": "AdaptiveCard",
                        "version": "1.3",
                        "body": [
                            {
                                "type": "TextBlock",
                                "text": $title,
                                "weight": "Bolder",
                                "wrap": true
                            },
                            {
                                "type": "TextBlock",
                                "text": ("Found " + $commits + " commits across " + $repos + " repositories"),
                                "wrap": true
                            },
                            {
                                "type": "TextBlock",
                                "text": $summary,
                                "wrap": true
                            }
                        ]
                    }
                }]
            }')
        
        echo "📤 Sending simplified payload..."
        send_webhook "$SIMPLE_PAYLOAD" || echo "❌ Both complex and simple payloads failed"
    fi
}

# Run main function
main