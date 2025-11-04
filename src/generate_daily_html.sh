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

# --- Get ecoregion config from YAML ---
ECOREGION_CONFIG=$(Rscript -e "
suppressPackageStartupMessages(library(yaml))
config <- read_yaml('$PROJECT_DIR/config/ecoregions.yaml')
ecoregion <- config\$ecoregions[[which(sapply(config\$ecoregions, function(x) x\$name_clean == '$ECOREGION'))]]
if (is.null(ecoregion)) {
  stop('Ecoregion $ECOREGION not found in config')
}
# Output: NAME|PARK1 PARK2 PARK3
parks <- ecoregion\$parks
if (is.null(parks) || length(parks) == 0) {
  cat(paste0(ecoregion\$name, '|'))
} else {
  cat(paste0(ecoregion\$name, '|', paste(parks, collapse=' ')))
}
")

# Parse the output
ECOREGION_NAME=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f1)
PARK_CODES=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f2)

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

# --- Generate dynamic park navigation and sections ---
if [ -n "$PARK_CODES" ]; then
  echo "Processing park analyses for: $PARK_CODES"

  # Build park navigation HTML
  PARK_NAV_HTML=""
  FIRST_PARK=true
  for PARK_CODE in $PARK_CODES; do
    if [ "$FIRST_PARK" = true ]; then
      PARK_NAV_HTML+="            <li><a href=\"javascript:void(0)\" class=\"park-link active\" onclick=\"showPark('$PARK_CODE')\">$PARK_CODE</a></li>\n"
      FIRST_PARK=false
    else
      PARK_NAV_HTML+="            <li><a href=\"javascript:void(0)\" class=\"park-link\" onclick=\"showPark('$PARK_CODE')\">$PARK_CODE</a></li>\n"
    fi
  done

  # Build park sections HTML
  PARK_SECTIONS_HTML=""
  FIRST_PARK=true
  for PARK_CODE in $PARK_CODES; do
    if [ "$FIRST_PARK" = true ]; then
      PARK_SECTIONS_HTML+="        <div id=\"$PARK_CODE\" class=\"park-plots\">\n"
      FIRST_PARK=false
    else
      PARK_SECTIONS_HTML+="        <div id=\"$PARK_CODE\" class=\"park-plots\" style=\"display:none;\">\n"
    fi
    PARK_SECTIONS_HTML+="          __${PARK_CODE}_ANALYSIS__\n"
    PARK_SECTIONS_HTML+="          <h3 style=\"margin-top: 30px;\">Threshold Plots - Forecast Trend</h3>\n"
    PARK_SECTIONS_HTML+="          <p style=\"font-size: 0.9em; color: #666; line-height: 1.6;\">These plots show how the percentage of park area at or above specific fire danger thresholds changes over the 7-day forecast period. Each threshold (0.25, 0.50, 0.75) represents the historical proportion of fires that occurred at or below that dryness level. Higher thresholds indicate more severe conditions. Use these trends to identify windows of opportunity for management activities or periods requiring heightened vigilance.</p>\n"
    PARK_SECTIONS_HTML+="          <h4>Threshold: 0.25</h4>\n"
    PARK_SECTIONS_HTML+="          <img src=\"$TODAY/parks/$PARK_CODE/threshold_plot_0.25.png\" alt=\"Fire Danger Threshold Plot at 0.25 for $PARK_CODE\">\n"
    PARK_SECTIONS_HTML+="          <h4>Threshold: 0.50</h4>\n"
    PARK_SECTIONS_HTML+="          <img src=\"$TODAY/parks/$PARK_CODE/threshold_plot_0.5.png\" alt=\"Fire Danger Threshold Plot at 0.50 for $PARK_CODE\">\n"
    PARK_SECTIONS_HTML+="          <h4>Threshold: 0.75</h4>\n"
    PARK_SECTIONS_HTML+="          <img src=\"$TODAY/parks/$PARK_CODE/threshold_plot_0.75.png\" alt=\"Fire Danger Threshold Plot at 0.75 for $PARK_CODE\">\n"
    PARK_SECTIONS_HTML+="        </div>\n\n"
  done

  # Replace the markers in the template
  awk -v nav="$PARK_NAV_HTML" '{
    if (index($0, "__PARK_NAVIGATION__") > 0) {
      gsub("__PARK_NAVIGATION__", nav)
    }
    print
  }' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
  mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

  awk -v sections="$PARK_SECTIONS_HTML" '{
    if (index($0, "__PARK_SECTIONS__") > 0) {
      gsub("__PARK_SECTIONS__", sections)
    }
    print
  }' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
  mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

  # Now insert the actual analysis content for each park
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
  echo "No parks configured for $ECOREGION. Removing park navigation and sections."
  # Replace markers with empty content if no parks are configured
  sed -i "s|__PARK_NAVIGATION__|<!-- No parks configured for this ecoregion -->|g" "$OUTPUT_FILE"
  sed -i "s|__PARK_SECTIONS__|<!-- No parks configured for this ecoregion -->|g" "$OUTPUT_FILE"
fi

# --- Replace date and path placeholders ---
sed -i -e "s|__DISPLAY_DATE__|$TODAY|g" \
       -e "s|__FORECAST_MAP_DATE__|$FORECAST_MAP_DATE|g" \
       -e "s|__FORECAST_MAP_PATH__|$FORECAST_MAP_PATH|g" \
       -e "s|__FORECAST_MAP_MOBILE_PATH__|$FORECAST_MAP_MOBILE_PATH|g" \
       -e "s|__ECOREGION__|$ECOREGION|g" \
       -e "s|__ECOREGION_NAME__|$ECOREGION_NAME|g" \
       "$OUTPUT_FILE"

echo "========================================="
echo "Successfully generated daily_forecast.html for $ECOREGION"
echo "Output: $OUTPUT_FILE"
echo "========================================="
