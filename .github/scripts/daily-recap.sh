#!/bin/bash

# Main orchestrator script for daily development recap

set -euo pipefail

# Set timezone to Pacific Time for all operations
export TZ='America/Los_Angeles'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed"
    exit 1
fi

echo "========================================="
echo "Daily Development Recap Generator"
echo "Running in Pacific Time ($(date +"%Y-%m-%d %H:%M:%S %Z"))"
echo "Script directory: $SCRIPT_DIR"
echo "========================================="

# Verify required environment variables
if [ -z "$TOKEN_GITHUB" ]; then
    echo "Error: TOKEN_GITHUB environment variable is not set"
    exit 1
fi

if [ -z "$OPENAI_API_KEY" ]; then
    echo "Error: OPENAI_API_KEY environment variable is not set"
    exit 1
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: WEBHOOK_URL environment variable is not set"
    exit 1
fi

if [ -z "$AUTHOR_ACCOUNT" ]; then
    echo "Error: AUTHOR_ACCOUNT environment variable is not set"
    echo "Please set AUTHOR_ACCOUNT to the GitHub username whose commits you want to find"
    exit 1
fi

# Temporary files
COMMITS_FILE="/tmp/daily_commits_$(date +%s).json"
SUMMARY_FILE="/tmp/daily_summary_$(date +%s).json"

# Cleanup function
cleanup() {
    rm -f "$COMMITS_FILE" "$SUMMARY_FILE"
}
trap cleanup EXIT

# Step 1: Fetch commits from all repositories
echo ""
echo "Step 1: Fetching commits from all repositories and branches..."
echo "-------------------------------------------------"
echo "Starting commit fetch process..."
echo "Output will be saved to: $COMMITS_FILE"

# Add debug information about the current date and timezone
echo "Current date/time: $(date)"
echo "Timezone: $TZ"
echo "Current day of week: $(date +%u)"

if ! bash "$SCRIPT_DIR/fetch-commits.sh" > "$COMMITS_FILE" 2>&1; then
    echo "Warning: Issues fetching some commits, continuing with available data" >&2
    echo "Check the fetch-commits.sh script output above for details"
fi

if [ ! -s "$COMMITS_FILE" ]; then
    echo "No commits file generated"
    COMMITS_FILE="/tmp/empty_commits.json"
    echo "[]" > "$COMMITS_FILE"
fi

# Validate JSON format
if ! jq . "$COMMITS_FILE" >/dev/null 2>&1; then
    echo "Warning: Invalid JSON in commits file, creating empty file"
    echo "[]" > "$COMMITS_FILE"
fi

COMMIT_COUNT=$(jq '. | length' "$COMMITS_FILE" 2>/dev/null || echo "0")
echo "Found $COMMIT_COUNT total commits"

# Show sample of commits for debugging
if [ "$COMMIT_COUNT" -gt 0 ]; then
    echo "Sample commits found:"
    jq -r '.[0:3] | .[] | "  - \(.repository): \(.message[0:50])..."' "$COMMITS_FILE" 2>/dev/null || echo "  Unable to display sample commits"
    if [ "$COMMIT_COUNT" -gt 3 ]; then
        echo "  ... and $((COMMIT_COUNT - 3)) more commits"
    fi
else
    echo "No commits found for the specified time period"
fi

# Step 2: Generate summary using ChatGPT
echo ""
echo "Step 2: Generating summary with ChatGPT..."
echo "-------------------------------------------------"
echo "Starting summary generation process..."
echo "Input commits file: $COMMITS_FILE"
echo "Output summary file: $SUMMARY_FILE"

if ! bash "$SCRIPT_DIR/generate-summary.sh" "$COMMITS_FILE" > "$SUMMARY_FILE" 2>&1; then
    echo "Warning: Issues generating summary, using fallback" >&2
    echo "Check the generate-summary.sh script output above for details"
    echo '{"summary": "Failed to generate summary", "commit_count": 0, "repo_count": 0, "bullet_points": ""}' > "$SUMMARY_FILE"
fi

if [ ! -s "$SUMMARY_FILE" ]; then
    echo "Failed to generate summary"
    exit 1
fi

# Validate summary JSON format
if ! jq . "$SUMMARY_FILE" >/dev/null 2>&1; then
    echo "Warning: Invalid JSON in summary file, using fallback"
    echo '{"summary": "Failed to generate summary", "commit_count": 0, "repo_count": 0, "bullet_points": ""}' > "$SUMMARY_FILE"
fi

echo "Summary generated successfully"

# Display summary preview
echo "Summary preview:"
jq -r '.summary' "$SUMMARY_FILE" 2>/dev/null | head -3 || echo "Unable to display summary preview"

# Step 3: Send to MS Teams
echo ""
echo "Step 3: Sending summary to MS Teams..."
echo "-------------------------------------------------"
echo "Starting webhook delivery process..."
echo "Target: MS Teams webhook"

if ! bash "$SCRIPT_DIR/send-webhook.sh" "$SUMMARY_FILE"; then
    echo "Warning: Failed to send to Teams, but recap was generated" >&2
    echo "Check the send-webhook.sh script output above for details"
fi

echo ""
echo "========================================="
echo "Daily recap completed successfully at $(date +"%H:%M:%S %Z")!"
echo "========================================="