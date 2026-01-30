#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get ecoregion from environment variable (required)
ECOREGION_NAME_CLEAN="${ECOREGION:-middle_rockies}"
echo "Processing lightning map for ecoregion: ${ECOREGION_NAME_CLEAN}"

if [ "${ENVIRONMENT}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Downloading necessary files from S3 ---"

  TODAY=$(date +%Y-%m-%d)
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

  S3_SOURCE_DIR="${S3_BUCKET_PATH}/out/forecasts/${ECOREGION_NAME_CLEAN}"
  LOCAL_FORECAST_DIR="/app/out/forecasts/${ECOREGION_NAME_CLEAN}"
  mkdir -p "$LOCAL_FORECAST_DIR"

  # Download NPS boundaries and ecoregion boundaries
  aws s3 sync "${S3_BUCKET_PATH}/data/nps_boundary" /app/data/nps_boundary
  aws s3 sync "${S3_BUCKET_PATH}/data/us_eco_l3" /app/data/us_eco_l3

  # Download park-specific analysis files
  aws s3 sync "${S3_SOURCE_DIR}/parks/" "${LOCAL_FORECAST_DIR}/parks/" 2>/dev/null || echo "No parks directory found in S3, will proceed without park analyses."

  # Try to download today's TIF. If it fails, try yesterday's.
  TODAY_TIF="${S3_SOURCE_DIR}/${TODAY}/fire_danger.tif"
  YESTERDAY_TIF="${S3_SOURCE_DIR}/${YESTERDAY}/fire_danger.tif"

  if aws s3 cp "$TODAY_TIF" "${LOCAL_FORECAST_DIR}/${TODAY}/" 2>/dev/null; then
    echo "Downloaded today's TIF."
  elif aws s3 cp "$YESTERDAY_TIF" "${LOCAL_FORECAST_DIR}/${YESTERDAY}/" 2>/dev/null; then
    echo "Downloaded yesterday's TIF as fallback."
  else
    echo "Error: Could not download a recent forecast TIF file from S3. Exiting."
    exit 1
  fi
else
  echo "--- Running in local mode: Skipping S3 sync ---"
fi

# This script orchestrates the creation of the hourly lightning map.

echo "Starting hourly lightning map generation..."

# It is assumed that the daily forecast process has already run.
# This script will find the latest available COG and use it.

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

TODAY_COG_FILE="out/forecasts/${ECOREGION_NAME_CLEAN}/${TODAY}/fire_danger.tif"
YESTERDAY_COG_FILE="out/forecasts/${ECOREGION_NAME_CLEAN}/${YESTERDAY}/fire_danger.tif"

COG_TO_USE=""
FORECAST_STATUS=""

if [ -f "$TODAY_COG_FILE" ]; then
  echo "Using current day's COG: $TODAY_COG_FILE"
  COG_TO_USE="$TODAY_COG_FILE"
  FORECAST_STATUS="Current"
elif [ -f "$YESTERDAY_COG_FILE" ]; then
  echo "Current day COG not found. Using previous day's COG: $YESTERDAY_COG_FILE"
  COG_TO_USE="$YESTERDAY_COG_FILE"
  FORECAST_STATUS="Previous Day"
else
  echo "Error: No recent COG file found for ${ECOREGION_NAME_CLEAN}. Exiting."
  exit 1
fi

# Run the R script to generate the map (pass ecoregion as 4th argument)
Rscript ./src/operational/visualization/map_lightning.R "$COG_TO_USE" "$FORECAST_STATUS" "$TODAY" "$ECOREGION_NAME_CLEAN"

Rscript ./src/operational/html_generation/generate_daily_html.R "${ECOREGION_NAME_CLEAN}"

if [ "${ENVIRONMENT}" = "cloud" ]; then
  echo "--- Running in cloud mode: Syncing specific HTML outputs to S3 ---"

  TODAY=$(date +%Y-%m-%d)
  LIGHTNING_MAP_FILE="/app/out/forecasts/${ECOREGION_NAME_CLEAN}/${TODAY}/lightning_map.html"
  DAILY_HTML_FILE="/app/out/forecasts/${ECOREGION_NAME_CLEAN}/daily_forecast.html"

  if [ -f "$LIGHTNING_MAP_FILE" ]; then
    aws s3 cp "$LIGHTNING_MAP_FILE" "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION_NAME_CLEAN}/${TODAY}/" --acl "public-read"
  else
    echo "Warning: Lightning map HTML file not found at $LIGHTNING_MAP_FILE"
  fi

  if [ -f "$DAILY_HTML_FILE" ]; then
    aws s3 cp "$DAILY_HTML_FILE" "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION_NAME_CLEAN}/" --acl "public-read"
  else
    echo "Warning: Daily HTML file not found at $DAILY_HTML_FILE"
  fi
fi

echo "Hourly lightning map generation complete for ${ECOREGION_NAME_CLEAN}."
