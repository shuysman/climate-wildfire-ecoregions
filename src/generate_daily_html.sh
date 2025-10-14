#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)

# Get the current date
TODAY=$(date +%Y-%m-%d)

# Path to the template file
TEMPLATE_FILE="$PROJECT_DIR/src/daily_forecast.template.html"

# Path to the output file
OUTPUT_FILE="$PROJECT_DIR/out/forecasts/daily_forecast.html"

# Use sed to replace the placeholder with the current date
sed "s/__DATE__/$TODAY/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Successfully generated daily_forecast.html"
