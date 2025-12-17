#!/usr/bin/env bash
# Generate per-ecoregion HTML dashboard
# Accepts ecoregion name as parameter

set -euo pipefail
IFS=$'\n\t'

# Get ecoregion from parameter, environment variable, or use default
ECOREGION=${1:-${ECOREGION:-middle_rockies}}

# Get the project directory (go up 3 levels: html_generation -> operational -> src -> project_root)
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)

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
# Output: NAME|PARK1 PARK2 PARK3|FOREST_VAR|FOREST_WINDOW|NON_FOREST_VAR|NON_FOREST_WINDOW
parks <- ecoregion\$parks
parks_str <- if (is.null(parks) || length(parks) == 0) '' else paste(parks, collapse=' ')
forest_var <- ecoregion\$cover_types\$forest\$variable
forest_window <- ecoregion\$cover_types\$forest\$window
non_forest_var <- ecoregion\$cover_types\$non_forest\$variable
non_forest_window <- ecoregion\$cover_types\$non_forest\$window
cat(paste0(ecoregion\$name, '|', parks_str, '|', forest_var, '|', forest_window, '|', non_forest_var, '|', non_forest_window))
" 2>/dev/null | tail -1)

# Parse the output
ECOREGION_NAME=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f1)
PARK_CODES=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f2)
FOREST_VARIABLE=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f3)
FOREST_WINDOW=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f4)
NON_FOREST_VARIABLE=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f5)
NON_FOREST_WINDOW=$(echo "$ECOREGION_CONFIG" | cut -d'|' -f6)

# Create human-readable variable names
get_variable_display() {
  local var=$1
  case "$var" in
    "vpd")
      echo "Vapor Pressure Deficit (VPD)"
      ;;
    "fm1000"|"fm1000inv")
      echo "1000-hour Fuel Moisture (FM1000)"
      ;;
    "fm100")
      echo "100-hour Fuel Moisture (FM100)"
      ;;
    "erc")
      echo "Energy Release Component (ERC)"
      ;;
    "cwd")
      echo "Climatic Water Deficit (CWD)"
      ;;
    "gdd_0")
      echo "Growing Degree Days (GDD₀)"
      ;;
    *)
      echo "$(echo "$var" | tr '[:lower:]' '[:upper:]')"
      ;;
  esac
}

# Check if variable is a flux type (uses rolling sum instead of average)
is_flux_variable() {
  local var=$1
  case "$var" in
    "cwd"|"gdd_0")
      return 0  # true - is flux
      ;;
    *)
      return 1  # false - is state
      ;;
  esac
}

# Generate methodology table HTML dynamically
generate_methodology_html() {
  local html=""

  # Forest row (only if forest cover type exists)
  if [ -n "$FOREST_VARIABLE" ] && [ "$FOREST_VARIABLE" != "NA" ]; then
    local forest_display=$(get_variable_display "$FOREST_VARIABLE")
    local forest_roll_type="rolling average"
    if is_flux_variable "$FOREST_VARIABLE"; then
      forest_roll_type="rolling sum"
    fi
    html+="                    <tr>\n"
    html+="                      <td style=\"padding: 5px 10px 5px 0; font-weight: 600;\">Forest Variable:</td>\n"
    html+="                      <td style=\"padding: 5px 0;\">$forest_display ($FOREST_WINDOW-day $forest_roll_type)</td>\n"
    html+="                    </tr>\n"
  fi

  # Non-forest row (only if non-forest cover type exists)
  if [ -n "$NON_FOREST_VARIABLE" ] && [ "$NON_FOREST_VARIABLE" != "NA" ]; then
    local non_forest_display=$(get_variable_display "$NON_FOREST_VARIABLE")
    local non_forest_roll_type="rolling average"
    if is_flux_variable "$NON_FOREST_VARIABLE"; then
      non_forest_roll_type="rolling sum"
    fi
    html+="                    <tr>\n"
    html+="                      <td style=\"padding: 5px 10px 5px 0; font-weight: 600;\">Non-forest Variable:</td>\n"
    html+="                      <td style=\"padding: 5px 0;\">$non_forest_display ($NON_FOREST_WINDOW-day $non_forest_roll_type)</td>\n"
    html+="                    </tr>"
  fi

  echo -e "$html"
}

METHODOLOGY_TABLE_HTML=$(generate_methodology_html)

# --- Check for stale data warnings ---
# Map variable names to their forecast data directories
# (e.g., fm1000inv uses fm1000 data)
get_forecast_variable() {
  local var=$1
  case "$var" in
    "fm1000inv")
      echo "fm1000"
      ;;
    *)
      echo "$var"
      ;;
  esac
}

generate_stale_warning_html() {
  local stale_vars=()

  # Get forecast variables (mapped from config variable names)
  local forest_forecast_var=""
  local non_forest_forecast_var=""

  if [ -n "$FOREST_VARIABLE" ] && [ "$FOREST_VARIABLE" != "NA" ]; then
    forest_forecast_var=$(get_forecast_variable "$FOREST_VARIABLE")
  fi
  if [ -n "$NON_FOREST_VARIABLE" ] && [ "$NON_FOREST_VARIABLE" != "NA" ]; then
    non_forest_forecast_var=$(get_forecast_variable "$NON_FOREST_VARIABLE")
  fi

  # Check if both use the same forecast variable
  local same_variable=false
  if [ -n "$forest_forecast_var" ] && [ "$forest_forecast_var" = "$non_forest_forecast_var" ]; then
    same_variable=true
  fi

  # Check forest variable
  if [ -n "$forest_forecast_var" ]; then
    local warning_file="$PROJECT_DIR/data/forecasts/${forest_forecast_var}/STALE_DATA_WARNING.txt"
    if [ -f "$warning_file" ]; then
      if [ "$same_variable" = true ]; then
        # Same variable used for both cover types - no qualifier needed
        stale_vars+=("$(get_variable_display "$FOREST_VARIABLE")")
        echo "Warning: Stale data detected for $FOREST_VARIABLE (all cover types)" >&2
      else
        stale_vars+=("$(get_variable_display "$FOREST_VARIABLE") (forest)")
        echo "Warning: Stale data detected for $FOREST_VARIABLE (forest)" >&2
      fi
    fi
  fi

  # Check non-forest variable (only if different from forest)
  if [ -n "$non_forest_forecast_var" ] && [ "$same_variable" = false ]; then
    local warning_file="$PROJECT_DIR/data/forecasts/${non_forest_forecast_var}/STALE_DATA_WARNING.txt"
    if [ -f "$warning_file" ]; then
      stale_vars+=("$(get_variable_display "$NON_FOREST_VARIABLE") (non-forest)")
      echo "Warning: Stale data detected for $NON_FOREST_VARIABLE (non-forest)" >&2
    fi
  fi

  # Generate HTML if any stale warnings found
  if [ ${#stale_vars[@]} -gt 0 ]; then
    local vars_list=$(printf ", %s" "${stale_vars[@]}")
    vars_list=${vars_list:2}  # Remove leading ", "

    cat <<EOF
    <div class="stale-data-warning">
      <h4>⚠️ Stale Forecast Data Warning</h4>
      <p>Today's forecast for <strong>${vars_list}</strong> was not available from the upstream data provider. This forecast is using yesterday's data for the affected variable(s). Forecast accuracy may be reduced.</p>
    </div>
EOF
  fi
}

STALE_WARNING_HTML=$(generate_stale_warning_html)

# --- Define paths using new directory structure ---
ECOREGION_OUT_DIR="$PROJECT_DIR/out/forecasts/$ECOREGION"
TODAY_DIR="$ECOREGION_OUT_DIR/$TODAY"
YESTERDAY_DIR="$ECOREGION_OUT_DIR/$YESTERDAY"

TEMPLATE_FILE="$PROJECT_DIR/src/operational/html_generation/daily_forecast.template.html"
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

# --- Generate ecoregion dropdown ---
echo "Generating ecoregion dropdown..."

# Get all enabled ecoregions from config
ALL_ECOREGIONS=$(Rscript -e "
suppressPackageStartupMessages(library(yaml))
config <- read_yaml('$PROJECT_DIR/config/ecoregions.yaml')
enabled <- config\$ecoregions[sapply(config\$ecoregions, function(x) isTRUE(x\$enabled))]
for (eco in enabled) {
  cat(eco\$name_clean, '|', eco\$name, '\\n', sep='')
}
" 2>/dev/null | tail -n +1)

ECOREGION_DROPDOWN_HTML=""
while IFS='|' read -r name_clean name; do
  if [ "$name_clean" = "$ECOREGION" ]; then
    # Current ecoregion - mark as selected with checkmark
    ECOREGION_DROPDOWN_HTML+="            <a href=\"../$name_clean/daily_forecast.html\"><strong>✓ $name</strong></a>\n"
  else
    ECOREGION_DROPDOWN_HTML+="            <a href=\"../$name_clean/daily_forecast.html\">$name</a>\n"
  fi
done <<< "$ALL_ECOREGIONS"

# Replace the ecoregion dropdown placeholder
awk -v dropdown="$ECOREGION_DROPDOWN_HTML" '{
  if (index($0, "__ECOREGION_DROPDOWN__") > 0) {
    gsub("__ECOREGION_DROPDOWN__", dropdown)
  }
  print
}' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

# --- Generate dynamic park navigation and sections ---
if [ -n "$PARK_CODES" ]; then
  echo "Processing park analyses for: $PARK_CODES"

  # Temporarily reset IFS to split on spaces
  OLD_IFS="$IFS"
  IFS=' '

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
    PARK_SECTIONS_HTML+="          <h3 style=\"margin-top: 30px;\">Category Distribution Forecast</h3>\n"
    PARK_SECTIONS_HTML+="          <p style=\"font-size: 0.9em; color: #666; line-height: 1.6;\">This stacked bar chart shows how the distribution of fire danger categories changes across the 7-day forecast period. Each bar represents one day, with colors showing the percentage of park area in each fire danger category (Extreme ≥0.95, Very High 0.90-0.95, High 0.75-0.90, Elevated 0.50-0.75, Normal <0.50). Use this visualization to see when danger categories are shifting and plan accordingly.</p>\n"
    PARK_SECTIONS_HTML+="          <img src=\"$TODAY/parks/$PARK_CODE/forecast_distribution.png\" alt=\"Fire Danger Category Distribution Forecast for $PARK_CODE\" style=\"width: 100%; max-width: 1000px;\">\n"
    PARK_SECTIONS_HTML+="          <h3 style=\"margin-top: 40px;\">Threshold Plots - Forecast Trend</h3>\n"
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

  # Restore original IFS
  IFS="$OLD_IFS"
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

# Replace methodology table using awk (handles multiline content better)
awk -v table="$METHODOLOGY_TABLE_HTML" '{
  if (index($0, "__METHODOLOGY_TABLE__") > 0) {
    gsub("__METHODOLOGY_TABLE__", table)
  }
  print
}' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"

# Replace stale data warning placeholder
if [ -n "$STALE_WARNING_HTML" ]; then
  awk -v warning="$STALE_WARNING_HTML" '{
    if (index($0, "__STALE_DATA_WARNING__") > 0) {
      gsub("__STALE_DATA_WARNING__", warning)
    }
    print
  }' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp"
  mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
else
  # No warning - just remove the placeholder
  sed -i 's|__STALE_DATA_WARNING__||g' "$OUTPUT_FILE"
fi

echo "========================================="
echo "Successfully generated daily_forecast.html for $ECOREGION"
echo "Output: $OUTPUT_FILE"
echo "========================================="
