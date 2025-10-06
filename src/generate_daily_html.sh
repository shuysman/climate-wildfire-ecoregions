#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the current date
TODAY=$(date +%Y-%m-%d)

# Path to the template file
TEMPLATE_FILE="/home/steve/sync/pyrome-fire/src/daily_forecast.template.html"

# Path to the output file
OUTPUT_FILE="/home/steve/sync/pyrome-fire/out/forecasts/daily_forecast.html"

# Use sed to replace the placeholder with the current date
sed "s/__DATE__/$TODAY/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Successfully generated daily_forecast.html"
