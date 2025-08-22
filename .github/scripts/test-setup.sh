#!/bin/bash

# Test script to validate daily-recap setup

set -euo pipefail

echo "========================================="
echo "Daily Recap Setup Validation"
echo "========================================="

# Check required tools
echo "Checking required tools..."
if command -v jq &> /dev/null; then
    echo "✓ jq is available: $(jq --version)"
else
    echo "✗ jq is not installed"
    exit 1
fi

if command -v curl &> /dev/null; then
    echo "✓ curl is available: $(curl --version | head -1)"
else
    echo "✗ curl is not installed"
    exit 1
fi

if command -v bash &> /dev/null; then
    echo "✓ bash is available: $(bash --version | head -1)"
else
    echo "✗ bash is not installed"
    exit 1
fi

# Check environment variables
echo ""
echo "Checking environment variables..."
if [ -n "${TOKEN_GITHUB:-}" ]; then
    echo "✓ TOKEN_GITHUB is set"
else
    echo "✗ TOKEN_GITHUB is not set"
    exit 1
fi

if [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "✓ OPENAI_API_KEY is set"
else
    echo "✗ OPENAI_API_KEY is not set"
    exit 1
fi

if [ -n "${WEBHOOK_URL:-}" ]; then
    echo "✓ WEBHOOK_URL is set"
else
    echo "✗ WEBHOOK_URL is not set"
    exit 1
fi

if [ -n "${AUTHOR_ACCOUNT:-}" ]; then
    echo "✓ AUTHOR_ACCOUNT is set: $AUTHOR_ACCOUNT"
else
    echo "✗ AUTHOR_ACCOUNT is not set"
    exit 1
fi

# Test GitHub authentication
echo ""
echo "Testing GitHub authentication..."
GITHUB_USER=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/user" | jq -r '.login' 2>/dev/null || echo "")

if [ -n "$GITHUB_USER" ] && [ "$GITHUB_USER" != "null" ]; then
    echo "✓ GitHub authentication successful: $GITHUB_USER"
else
    echo "✗ GitHub authentication failed"
    echo "Response: $(curl -s -H "Authorization: token $TOKEN_GITHUB" "https://api.github.com/user")"
    exit 1
fi

# Test author account access
echo ""
echo "Testing author account access..."
AUTHOR_RESPONSE=$(curl -s -H "Authorization: token $TOKEN_GITHUB" \
    "https://api.github.com/users/$AUTHOR_ACCOUNT" 2>/dev/null || echo '{"error": "Failed to fetch user"}')

if echo "$AUTHOR_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo "✗ Cannot access author account: $AUTHOR_ACCOUNT"
    echo "Response: $AUTHOR_RESPONSE"
    exit 1
else
    AUTHOR_NAME=$(echo "$AUTHOR_RESPONSE" | jq -r '.name // .login' 2>/dev/null || echo "$AUTHOR_ACCOUNT")
    echo "✓ Author account accessible: $AUTHOR_NAME ($AUTHOR_ACCOUNT)"
fi

# Test OpenAI API
echo ""
echo "Testing OpenAI API..."
OPENAI_RESPONSE=$(curl -s -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 10
    }' 2>/dev/null || echo '{"error": "API call failed"}')

if echo "$OPENAI_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo "✗ OpenAI API test failed"
    echo "Response: $OPENAI_RESPONSE"
    exit 1
else
    echo "✓ OpenAI API test successful"
fi

# Test webhook URL format
echo ""
echo "Testing webhook URL format..."
if [[ "$WEBHOOK_URL" =~ ^https://outlook\.office\.com/webhook/ ]]; then
    echo "✓ Webhook URL format appears correct"
else
    echo "⚠ Webhook URL format may be incorrect (should start with https://outlook.office.com/webhook/)"
fi

# Check script permissions
echo ""
echo "Checking script permissions..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for script in daily-recap.sh fetch-commits.sh generate-summary.sh send-webhook.sh; do
    if [ -x "$SCRIPT_DIR/$script" ]; then
        echo "✓ $script is executable"
    else
        echo "✗ $script is not executable"
        chmod +x "$SCRIPT_DIR/$script" 2>/dev/null && echo "  → Made executable"
    fi
done

# Test date functionality
echo ""
echo "Testing date functionality..."
if date +%u >/dev/null 2>&1; then
    echo "✓ Basic date functionality works"
    echo "  Current day of week: $(date +%u)"
    echo "  Current date: $(date)"
else
    echo "✗ Date functionality failed"
    exit 1
fi

# Test JSON processing
echo ""
echo "Testing JSON processing..."
TEST_JSON='{"test": "value", "number": 123}'
if echo "$TEST_JSON" | jq . >/dev/null 2>&1; then
    echo "✓ JSON processing works"
else
    echo "✗ JSON processing failed"
    exit 1
fi

echo ""
echo "========================================="
echo "Setup validation completed successfully!"
echo "Your daily-recap system is ready to use."
echo "========================================="
