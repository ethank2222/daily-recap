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
    elif echo "$WEBHOOK_URL" | grep -q "office.com"; then
        echo "📤 Sending summary to Teams webhook"
        WEBHOOK_TYPE="teams"
    else
        echo "📤 Sending summary to webhook"
        WEBHOOK_TYPE="generic"
    fi
    
    return 0
}

# Create Teams payload
create_teams_payload() {
    local summary="$1"
    local title="$2"
    local time="$3"
    local period="$4"
    local url="$5"
    
    # Format summary for Teams (ensure line breaks)
    local formatted_summary=$(echo "$summary" | sed 's/• /\n• /g' | sed 's/📁/\n\n📁/g' | sed 's/^\n\n//')
    local escaped_summary=$(echo "$formatted_summary" | jq -Rs .)
    
    # Detect Teams webhook version
    if echo "$WEBHOOK_URL" | grep -q "webhook.office.com/webhookb2"; then
        echo "📋 Detected native Teams Incoming Webhook"
        # Native Teams Incoming Webhook - MessageCard format
        jq -n \
            --arg title "$title" \
            --arg time "$time" \
            --arg repos "$REPO_COUNT" \
            --arg commits "$COMMIT_COUNT" \
            --arg period "$period" \
            --argjson summary "$escaped_summary" \
            --arg url "$url" \
            '{
                "@type": "MessageCard",
                "@context": "https://schema.org/extensions",
                "themeColor": "0078D4",
                "title": $title,
                "summary": ("Commits: " + $commits + " | Repos: " + $repos),
                "sections": [
                    {
                        "activityTitle": $time,
                        "facts": [
                            {
                                "name": "📚 Repositories Checked",
                                "value": $repos
                            },
                            {
                                "name": "💻 Commits Found",
                                "value": $commits
                            },
                            {
                                "name": "📅 Time Period",
                                "value": $period
                            }
                        ]
                    },
                    {
                        "title": "**Summary of Work Completed**",
                        "text": $summary
                    }
                ],
                "potentialAction": [
                    {
                        "@type": "OpenUri",
                        "name": "🔍 View Workflow Run",
                        "targets": [
                            {
                                "os": "default",
                                "uri": $url
                            }
                        ]
                    }
                ]
            }'
    else
        echo "📋 Using Power Automate/Teams Webhook format"
        # Power Automate or other webhook - AdaptiveCard format
        jq -n \
            --arg title "$title" \
            --arg time "$time" \
            --arg repos "$REPO_COUNT" \
            --arg commits "$COMMIT_COUNT" \
            --arg period "$period" \
            --argjson summary "$escaped_summary" \
            --arg url "$url" \
            '{
                type: "message",
                attachments: [{
                    contentType: "application/vnd.microsoft.card.adaptive",
                    content: {
                        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                        type: "AdaptiveCard",
                        version: "1.3",
                        body: [
                            {
                                type: "Container",
                                style: "emphasis",
                                bleed: true,
                                items: [
                                    {
                                        type: "TextBlock",
                                        text: $title,
                                        size: "Large",
                                        weight: "Bolder",
                                        color: "Accent",
                                        wrap: true
                                    },
                                    {
                                        type: "TextBlock",
                                        text: $time,
                                        size: "Small",
                                        color: "Default",
                                        spacing: "None",
                                        wrap: true
                                    }
                                ]
                            },
                            {
                                type: "FactSet",
                                facts: [
                                    {
                                        title: "📚 Repositories Checked",
                                        value: $repos
                                    },
                                    {
                                        title: "💻 Commits Found",
                                        value: $commits
                                    },
                                    {
                                        title: "📅 Time Period",
                                        value: $period
                                    }
                                ],
                                spacing: "Medium"
                            },
                            {
                                type: "Container",
                                style: "default",
                                items: [
                                    {
                                        type: "TextBlock",
                                        text: "**Summary of Work Completed**",
                                        size: "Medium",
                                        weight: "Bolder",
                                        color: "Default",
                                        spacing: "Medium",
                                        wrap: true
                                    },
                                    {
                                        type: "TextBlock",
                                        text: $summary,
                                        wrap: true,
                                        spacing: "Small"
                                    }
                                ]
                            }
                        ],
                        actions: [
                            {
                                type: "Action.OpenUrl",
                                title: "🔍 View Workflow Run",
                                url: $url,
                                style: "positive"
                            }
                        ]
                    }
                }]
            }'
    fi
}

# Send webhook with retry logic
send_webhook() {
    local payload="$1"
    local max_retries=3
    local retry_delay=2
    
    echo "📤 Attempting to send webhook..."
    echo "📋 Using Teams Webhook format with AdaptiveCard"
    
    for i in $(seq 1 $max_retries); do
        # Send request
        local http_status=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 10 \
            -X POST \
            -H "Content-Type: application/json; charset=utf-8" \
            -H "Accept: application/json" \
            -d "$payload" \
            "$WEBHOOK_URL" 2>/dev/null || echo "000")
        
        # Check for success
        if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
            echo "✅ Webhook delivered successfully (HTTP $http_status)"
            return 0
        fi
        
        echo "⚠️ Webhook delivery failed (HTTP $http_status, attempt $i/$max_retries)"
        
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
    send_webhook "$PAYLOAD"
}

# Run main function
main