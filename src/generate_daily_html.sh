#!/usr/bin/env bash
# Generate per-ecoregion HTML dashboard
# Accepts ecoregion name as parameter

set -euo pipefail
IFS=$'\n\t'

# Get ecoregion from parameter or use default
ECOREGION=${1:-middle_rockies}

# Get the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)

# Define dates
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

echo "========================================="
echo "Generating HTML dashboard for: $ECOREGION"
echo "Date: $TODAY"
echo "========================================="

# --- Get park list from YAML config ---
PARK_CODES=$(Rscript -e "
suppressPackageStartupMessages(library(yaml))
config <- read_yaml('$PROJECT_DIR/config/ecoregions.yaml')
ecoregion <- config\$ecoregions[[which(sapply(config\$ecoregions, function(x) x\$name_clean == '$ECOREGION'))]]
if (is.null(ecoregion)) {
  stop('Ecoregion $ECOREGION not found in config')
}
parks <- ecoregion\$parks
if (is.null(parks) || length(parks) == 0) {
  cat('')
} else {
  cat(paste(parks, collapse=' '))
}
")

# --- Define paths using new directory structure ---
ECOREGION_OUT_DIR="$PROJECT_DIR/out/forecasts/$ECOREGION"
TODAY_DIR="$ECOREGION_OUT_DIR/$TODAY"
YESTERDAY_DIR="$ECOREGION_OUT_DIR/$YESTERDAY"

TEMPLATE_FILE="$PROJECT_DIR/src/daily_forecast.template.html"
OUTPUT_FILE="$ECOREGION_OUT_DIR/daily_forecast.html"

# --- Check for forecast map (today or yesterday fallback) ---
TODAY_FORECAST_MAP="$TODAY_DIR/fire_danger_forecast.png"
TODAY_FORECAST_MAP_MOBILE="$TODAY_DIR/fire_danger_forecast_mobile.png"

if [ -f "$TODAY_FORECAST_MAP" ]; then
  FORECAST_MAP_DATE="$TODAY"
  FORECAST_MAP_PATH="$TODAY/fire_danger_forecast.png"
  FORECAST_MAP_MOBILE_PATH="$TODAY/fire_danger_forecast_mobile.png"
else
  echo "Warning: Today's forecast map not found. Falling back to yesterday's map."
  FORECAST_MAP_DATE="$YESTERDAY"
  FORECAST_MAP_PATH="$YESTERDAY/fire_danger_forecast.png"
  FORECAST_MAP_MOBILE_PATH="$YESTERDAY/fire_danger_forecast_mobile.png"
fi

# --- Start with the template ---
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Error: Template file not found at: $TEMPLATE_FILE" >&2
  exit 1
fi

cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# --- Insert park-specific analyses ---
if [ -n "$PARK_CODES" ]; then
  echo "Processing park analyses for: $PARK_CODES"

  for PARK_CODE in $PARK_CODES; do
    ANALYSIS_FILE="$TODAY_DIR/parks/$PARK_CODE/fire_danger_analysis.html"
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
      echo "Warning: Analysis file not found for $PARK_CODE at $ANALYSIS_FILE"
      # Replace placeholder with a message
      sed -i "s|$PLACEHOLDER|<p>Analysis not available for this park.</p>|g" "$OUTPUT_FILE"
    fi
  done

  # Remove any remaining placeholders (in case template has placeholders for parks not in this ecoregion)
  sed -i 's|__[A-Z]\{4\}_ANALYSIS__|<!-- Park not configured for this ecoregion -->|g' "$OUTPUT_FILE"
else
  echo "No parks configured for $ECOREGION. Removing all park placeholders."
  # Remove all park placeholders if no parks are configured
  sed -i 's|__[A-Z]\{4\}_ANALYSIS__|<!-- No parks configured -->|g' "$OUTPUT_FILE"
fi

# --- Replace date and path placeholders ---
sed -i -e "s|__DISPLAY_DATE__|$TODAY|g" \
       -e "s|__FORECAST_MAP_DATE__|$FORECAST_MAP_DATE|g" \
       -e "s|__FORECAST_MAP_PATH__|$FORECAST_MAP_PATH|g" \
       -e "s|__FORECAST_MAP_MOBILE_PATH__|$FORECAST_MAP_MOBILE_PATH|g" \
       -e "s|__ECOREGION__|$ECOREGION|g" \
       "$OUTPUT_FILE"

echo "========================================="
echo "Successfully generated daily_forecast.html for $ECOREGION"
echo "Output: $OUTPUT_FILE"
echo "========================================="
