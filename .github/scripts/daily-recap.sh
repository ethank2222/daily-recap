#!/bin/bash

# Main orchestrator script for daily development recap

set -euo pipefail

# Set timezone to Pacific Time for all operations
export TZ='America/Los_Angeles'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Daily Development Recap Generator"
echo "Running in Pacific Time ($(date +"%Y-%m-%d %H:%M:%S %Z"))"
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

if ! bash "$SCRIPT_DIR/fetch-commits.sh" > "$COMMITS_FILE" 2>&1; then
    echo "Warning: Issues fetching some commits, continuing with available data" >&2
fi

if [ ! -s "$COMMITS_FILE" ]; then
    echo "No commits file generated"
    COMMITS_FILE="/tmp/empty_commits.json"
    echo "[]" > "$COMMITS_FILE"
fi

COMMIT_COUNT=$(jq '. | length' "$COMMITS_FILE")
echo "Found $COMMIT_COUNT total commits"

# Step 2: Generate summary using ChatGPT
echo ""
echo "Step 2: Generating summary with ChatGPT..."
echo "-------------------------------------------------"

if ! bash "$SCRIPT_DIR/generate-summary.sh" "$COMMITS_FILE" > "$SUMMARY_FILE" 2>&1; then
    echo "Warning: Issues generating summary, using fallback" >&2
    echo '{"summary": "Failed to generate summary", "commit_count": 0, "repo_count": 0, "bullet_points": ""}' > "$SUMMARY_FILE"
fi

if [ ! -s "$SUMMARY_FILE" ]; then
    echo "Failed to generate summary"
    exit 1
fi

echo "Summary generated successfully"

# Step 3: Send to MS Teams
echo ""
echo "Step 3: Sending summary to MS Teams..."
echo "-------------------------------------------------"

if ! bash "$SCRIPT_DIR/send-webhook.sh" "$SUMMARY_FILE"; then
    echo "Warning: Failed to send to Teams, but recap was generated" >&2
fi

echo ""
echo "========================================="
echo "Daily recap completed successfully at $(date +"%H:%M:%S %Z")!"
echo "========================================="