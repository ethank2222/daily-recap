#!/bin/bash

# Test script to debug date calculations

set -euo pipefail

echo "========================================="
echo "Date Calculation Debug"
echo "========================================="

# Set timezone to Pacific Time
export TZ='America/Los_Angeles'

echo "Current timezone: $TZ"
echo "Current date/time: $(date)"
echo "Current day of week: $(date +%u)"

# Test the date calculation logic
get_date_range() {
    local day_of_week=$(date +%u)
    
    if [ "$day_of_week" -eq 1 ]; then
        # It's Monday, look at Friday
        if command -v gdate &> /dev/null; then
            # macOS with coreutils
            SINCE_DATE=$(gdate -d "last Friday" +%Y-%m-%d)
            UNTIL_DATE=$(gdate -d "last Saturday" +%Y-%m-%d)
        elif date --version &> /dev/null; then
            # Linux GNU date
            SINCE_DATE=$(date -d "last Friday" +%Y-%m-%d)
            UNTIL_DATE=$(date -d "last Saturday" +%Y-%m-%d)
        else
            # BSD/macOS default date
            SINCE_DATE=$(date -v-3d +%Y-%m-%d)
            UNTIL_DATE=$(date -v-2d +%Y-%m-%d)
        fi
    else
        # Look at yesterday
        if command -v gdate &> /dev/null; then
            # macOS with coreutils
            SINCE_DATE=$(gdate -d "yesterday" +%Y-%m-%d)
            UNTIL_DATE=$(gdate +%Y-%m-%d)
        elif date --version &> /dev/null; then
            # Linux GNU date
            SINCE_DATE=$(date -d "yesterday" +%Y-%m-%d)
            UNTIL_DATE=$(date +%Y-%m-%d)
        else
            # BSD/macOS default date
            SINCE_DATE=$(date -v-1d +%Y-%m-%d)
            UNTIL_DATE=$(date +%Y-%m-%d)
        fi
    fi
    
    echo "Day of week: $day_of_week"
    echo "Since date: $SINCE_DATE"
    echo "Until date: $UNTIL_DATE"
    
    # Show the UTC conversions
    local since_utc="${SINCE_DATE}T07:00:00Z"
    local until_utc="${UNTIL_DATE}T08:59:59Z"
    
    echo "Since UTC: $since_utc"
    echo "Until UTC: $until_utc"
    
    # Show what this means in local time
    echo "Local time range: $SINCE_DATE 00:00 to $UNTIL_DATE 23:59 (Pacific Time)"
}

echo ""
echo "Date calculation results:"
echo "-------------------------"
get_date_range

echo ""
echo "Testing different date ranges:"
echo "-----------------------------"

# Test yesterday
echo "Yesterday: $(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "Failed")"

# Test last Friday
echo "Last Friday: $(date -d "last Friday" +%Y-%m-%d 2>/dev/null || date -v-3d +%Y-%m-%d 2>/dev/null || echo "Failed")"

# Test last 7 days
echo "Last 7 days:"
for i in {1..7}; do
    date_val=$(date -d "$i days ago" +%Y-%m-%d 2>/dev/null || date -v-${i}d +%Y-%m-%d 2>/dev/null || echo "Failed")
    echo "  $i days ago: $date_val"
done

echo ""
echo "========================================="
echo "Date debug completed"
echo "========================================="
