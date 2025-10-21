#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)

# Define dates
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

# --- Define placeholder values ---

# The display date in the title is always today
DISPLAY_DATE="$TODAY"

# The lightning map always uses today's date in its filename because it has its own internal fallback
LIGHTNING_MAP_DATE="$TODAY"

# For the main forecast map, check if today's exists and fall back to yesterday's if not
TODAY_FORECAST_MAP="$PROJECT_DIR/out/forecasts/middle_rockies_fire_danger_forecast_${TODAY}.png"

if [ -f "$TODAY_FORECAST_MAP" ]; then
  FORECAST_MAP_DATE="$TODAY"
else
  echo "Warning: Today's forecast map not found. Falling back to yesterday's map."
  FORECAST_MAP_DATE="$YESTERDAY"
fi

# --- Paths ---
TEMPLATE_FILE="$PROJECT_DIR/src/daily_forecast.template.html"
OUTPUT_FILE="$PROJECT_DIR/out/forecasts/daily_forecast.html"

# --- Generate HTML ---
# Use a chain of sed commands to replace each unique placeholder
sed -e "s/__DISPLAY_DATE__/$DISPLAY_DATE/g" \
    -e "s/__FORECAST_MAP_DATE__/$FORECAST_MAP_DATE/g" \
    -e "s/__LIGHTNING_MAP_DATE__/$LIGHTNING_MAP_DATE/g" \
    "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "Successfully generated daily_forecast.html"
