#!/bin/bash

# Debug script to help identify JSON parsing issues

set -euo pipefail

echo "========================================="
echo "JSON Debug Script for Daily Recap"
echo "========================================="

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

echo "jq version: $(jq --version)"

# Test basic JSON parsing
echo ""
echo "Testing basic JSON parsing..."
echo '{"test": "value"}' | jq . >/dev/null && echo "✓ Basic JSON parsing works" || echo "✗ Basic JSON parsing failed"

# Test with special characters
echo ""
echo "Testing JSON with special characters..."
echo '{"message": "test \"quote\" and \\backslash"}' | jq . >/dev/null && echo "✓ Special character JSON parsing works" || echo "✗ Special character JSON parsing failed"

# Test with newlines
echo ""
echo "Testing JSON with newlines..."
echo '{"message": "line1\nline2"}' | jq . >/dev/null && echo "✓ Newline JSON parsing works" || echo "✗ Newline JSON parsing failed"

# Test with control characters
echo ""
echo "Testing JSON with control characters..."
echo '{"message": "test\r\nmessage"}' | jq . >/dev/null && echo "✓ Control character JSON parsing works" || echo "✗ Control character JSON parsing failed"

# Check for any existing commit files
echo ""
echo "Checking for existing commit files..."
for file in /tmp/daily_commits_*.json; do
    if [ -f "$file" ]; then
        echo "Found file: $file"
        if jq . "$file" >/dev/null 2>&1; then
            echo "✓ File contains valid JSON"
            COMMIT_COUNT=$(jq '. | length' "$file" 2>/dev/null || echo "0")
            echo "  Contains $COMMIT_COUNT commits"
        else
            echo "✗ File contains invalid JSON"
            echo "  First 100 characters:"
            head -c 100 "$file" | cat -A
            echo ""
        fi
    fi
done

# Check for any existing summary files
echo ""
echo "Checking for existing summary files..."
for file in /tmp/daily_summary_*.json; do
    if [ -f "$file" ]; then
        echo "Found file: $file"
        if jq . "$file" >/dev/null 2>&1; then
            echo "✓ File contains valid JSON"
        else
            echo "✗ File contains invalid JSON"
            echo "  First 100 characters:"
            head -c 100 "$file" | cat -A
            echo ""
        fi
    fi
done

echo ""
echo "========================================="
echo "Debug script completed"
echo "========================================="
