#!/usr/bin/env bash
# Create a single-layer Cloud-Optimized GeoTIFF (COG) for today's fire danger forecast
# Accepts ecoregion name as parameter

set -euo pipefail
IFS=$'\n\t'

# Get ecoregion from parameter or use default
ECOREGION=${1:-middle_rockies}

echo "========================================="
echo "Creating COG for $ECOREGION forecast"
echo "========================================="

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

# Define source NetCDF files using new directory structure
TODAY_FORECAST_NC="out/forecasts/${ECOREGION}/${TODAY}/fire_danger_forecast.nc"
YESTERDAY_FORECAST_NC="out/forecasts/${ECOREGION}/${YESTERDAY}/fire_danger_forecast.nc"

SOURCE_NC=""
SOURCE_DATE=""
OUTPUT_DIR=""

if [ -f "$TODAY_FORECAST_NC" ]; then
  echo "Today's forecast NetCDF found: $TODAY_FORECAST_NC"
  SOURCE_NC="$TODAY_FORECAST_NC"
  SOURCE_DATE="$TODAY"
  OUTPUT_DIR="out/forecasts/${ECOREGION}/${TODAY}"
elif [ -f "$YESTERDAY_FORECAST_NC" ]; then
  echo "Today's forecast NetCDF not found. Falling back to yesterday's: $YESTERDAY_FORECAST_NC"
  SOURCE_NC="$YESTERDAY_FORECAST_NC"
  SOURCE_DATE="$YESTERDAY"
  OUTPUT_DIR="out/forecasts/${ECOREGION}/${YESTERDAY}"
else
  echo "Error: No source NetCDF file found for $ECOREGION. Exiting."
  exit 1
fi

# Define the COG output file in the same directory as the source
COG_OUTPUT_FILE="${OUTPUT_DIR}/fire_danger.tif"

echo "Source: $SOURCE_NC"
echo "Output: $COG_OUTPUT_FILE"

# --- Convert the selected NetCDF to a COG ---
# Extract band 1 (today's forecast)
echo "Converting band 1 to Cloud-Optimized GeoTIFF..."

gdal_translate \
  -b 1 \
  -of COG \
  -co COMPRESS=DEFLATE \
  -co PREDICTOR=3 \
  -co NUM_THREADS=ALL_CPUS \
  "$SOURCE_NC" \
  "$COG_OUTPUT_FILE"

echo "========================================="
echo "COG creation complete"
echo "Output: $COG_OUTPUT_FILE"
echo "========================================="
