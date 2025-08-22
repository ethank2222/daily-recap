#!/bin/bash

# Send summary to MS Teams via webhook

set -euo pipefail

# Read summary data from stdin or file
if [ -n "$1" ]; then
    SUMMARY_DATA=$(cat "$1")
else
    SUMMARY_DATA=$(cat)
fi

# Extract values from the summary data
COMMIT_COUNT=$(echo "$SUMMARY_DATA" | jq -r '.commit_count // 0')
REPO_COUNT=$(echo "$SUMMARY_DATA" | jq -r '.repo_count // 0')
BULLET_POINTS=$(echo "$SUMMARY_DATA" | jq -r '.bullet_points // ""')

# Set timezone to Pacific Time
export TZ='America/Los_Angeles'

# Get the date for the summary in Pacific Time
if [ "$(date +%u)" -eq 1 ]; then
    SUMMARY_DATE="Friday, $(date -d "last Friday" +"%B %d, %Y")"
else
    SUMMARY_DATE="$(date -d "yesterday" +"%A, %B %d, %Y")"
fi

# Create the adaptive card body
if [ "$COMMIT_COUNT" -eq 0 ]; then
    # No commits found
    CARD_BODY='[
        {
            "type": "TextBlock",
            "text": "📊 **Daily Development Summary**",
            "weight": "Bolder",
            "size": "Large",
            "wrap": true
        },
        {
            "type": "TextBlock",
            "text": "Date: '"$SUMMARY_DATE"'",
            "wrap": true,
            "spacing": "Small"
        },
        {
            "type": "TextBlock",
            "text": "No development activity recorded for the previous workday.",
            "wrap": true,
            "spacing": "Medium"
        }
    ]'
else
    # Format bullet points for the card
    # Convert markdown bullet points to plain text for Teams
    FORMATTED_POINTS=$(echo "$BULLET_POINTS" | sed 's/^- /• /g' | sed 's/\*\*//g' | sed 's/`//g')
    
    # Escape special characters for JSON
    FORMATTED_POINTS=$(echo "$FORMATTED_POINTS" | jq -Rs .)
    
    CARD_BODY=$(jq -n \
        --arg date "$SUMMARY_DATE" \
        --arg commit_count "$COMMIT_COUNT" \
        --arg repo_count "$REPO_COUNT" \
        --argjson points "$FORMATTED_POINTS" \
        '[
            {
                "type": "TextBlock",
                "text": "🚀 **Yesterday'\''s Development Summary**",
                "weight": "Bolder",
                "wrap": true
            },
            {
                "type": "TextBlock",
                "text": "Date: " + $date,
                "wrap": true,
                "spacing": "Small"
            },
            {
                "type": "TextBlock",
                "text": "Found " + ($commit_count | tostring) + " commits across " + ($repo_count | tostring) + " repositories",
                "wrap": true,
                "spacing": "Medium",
                "weight": "Lighter"
            },
            {
                "type": "TextBlock",
                "text": "**Changes Made:**",
                "weight": "Bolder",
                "wrap": true,
                "spacing": "Medium"
            },
            {
                "type": "TextBlock",
                "text": $points,
                "wrap": true,
                "spacing": "Small"
            }
        ]')
fi

# Create the full webhook payload
WEBHOOK_PAYLOAD=$(jq -n \
    --argjson body "$CARD_BODY" \
    '{
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.3",
                    "body": $body
                }
            }
        ]
    }')

# Send to Teams webhook
echo "Sending summary to MS Teams..." >&2

RESPONSE=$(curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$WEBHOOK_PAYLOAD" \
    2>/dev/null)

# Check response
if [ "$RESPONSE" = "1" ] || [ -z "$RESPONSE" ]; then
    echo "Successfully sent summary to MS Teams" >&2
    exit 0
else
    echo "Warning: Unexpected response from Teams webhook: $RESPONSE" >&2
    # Don't fail the whole pipeline for webhook issues
    exit 0
fi