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
PARKS_DIR="$PROJECT_DIR/out/forecasts/parks"

# --- Start with the template ---
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# --- Insert park-specific analyses ---
for PARK_CODE in YELL GRTE JODR JECA GRKO DETO WICA MORU; do
  ANALYSIS_FILE="$PARKS_DIR/$PARK_CODE/fire_danger_analysis.html"
  PLACEHOLDER="__${PARK_CODE}_ANALYSIS__"

  if [ -f "$ANALYSIS_FILE" ]; then
    # Read the analysis file content
    ANALYSIS_CONTENT=$(cat "$ANALYSIS_FILE")
    # Use awk to replace the placeholder (handles special characters better than sed)
    awk -v placeholder="$PLACEHOLDER" -v content="$ANALYSIS_CONTENT" '
      {
        if (index($0, placeholder) > 0) {
          gsub(placeholder, content)
        }
        print
      }
    ' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
    mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
  else
    echo "Warning: Analysis file not found for $PARK_CODE"
    # Replace placeholder with a message
    sed -i "s|$PLACEHOLDER|<p>Analysis not available for this park.</p>|g" "$OUTPUT_FILE"
  fi
done

# --- Replace date placeholders ---
sed -i -e "s/__DISPLAY_DATE__/$DISPLAY_DATE/g" \
       -e "s/__FORECAST_MAP_DATE__/$FORECAST_MAP_DATE/g" \
       -e "s/__LIGHTNING_MAP_DATE__/$LIGHTNING_MAP_DATE/g" \
       "$OUTPUT_FILE"

echo "Successfully generated daily_forecast.html"
