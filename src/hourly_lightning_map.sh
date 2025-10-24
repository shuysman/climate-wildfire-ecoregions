#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ "${ENVIRONMENT}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Downloading necessary files from S3 ---"

  TODAY=$(date +%Y-%m-%d)
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
  ECOREGION_NAME_CLEAN="middle_rockies" # This is hardcoded in other scripts

  S3_SOURCE_DIR="${S3_BUCKET_PATH}/out/forecasts"
  LOCAL_FORECAST_DIR="/app/out/forecasts"
  mkdir -p "$LOCAL_FORECAST_DIR"

  # Define remote file paths
  TODAY_TIF="${S3_SOURCE_DIR}/fire_danger_${TODAY}.tif"
  YESTERDAY_TIF="${S3_SOURCE_DIR}/fire_danger_${YESTERDAY}.tif"
  TODAY_PNG="${S3_SOURCE_DIR}/${ECOREGION_NAME_CLEAN}_fire_danger_forecast_${TODAY}.png"
  YESTERDAY_PNG="${S3_SOURCE_DIR}/${ECOREGION_NAME_CLEAN}_fire_danger_forecast_${YESTERDAY}.png"

  aws s3 cp "${S3_BUCKET_PATH}/data/nps_boundary" /app/data/nps_boundary

  # Try to download today's TIF. If it fails (non-zero exit code), try yesterday's.
  if aws s3 cp "$TODAY_TIF" "${LOCAL_FORECAST_DIR}/" 2>/dev/null; then
    echo "Downloaded today's TIF."
    # If today's TIF exists, download today's PNG.
    aws s3 cp "$TODAY_PNG" "${LOCAL_FORECAST_DIR}/"
  elif aws s3 cp "$YESTERDAY_TIF" "${LOCAL_FORECAST_DIR}/" 2>/dev/null; then
    echo "Downloaded yesterday's TIF as fallback."
    # If yesterday's TIF exists, download yesterday's PNG.
    aws s3 cp "$YESTERDAY_PNG" "${LOCAL_FORECAST_DIR}/"
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

TODAY_COG_FILE="out/forecasts/fire_danger_${TODAY}.tif"
YESTERDAY_COG_FILE="out/forecasts/fire_danger_${YESTERDAY}.tif"

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
  echo "Error: No recent COG file found. Exiting."
  exit 1
fi

# Run the R script to generate the map
Rscript ./src/map_lightning.R "$COG_TO_USE" "$FORECAST_STATUS" "$TODAY"

./src/generate_daily_html.sh

if [ "${ENVIRONMENT}" = "cloud" ]; then
  echo "--- Running in cloud mode: Syncing specific HTML outputs to S3 ---"
  
  TODAY=$(date +%Y-%m-%d)
  LIGHTNING_MAP_FILE="/app/out/forecasts/lightning_map_${TODAY}.html"
  DAILY_HTML_FILE="/app/out/forecasts/daily_forecast.html"

  if [ -f "$LIGHTNING_MAP_FILE" ]; then
    aws s3 cp "$LIGHTNING_MAP_FILE" "${S3_BUCKET_PATH}/out/forecasts/" --acl "public-read"
  else
    echo "Warning: Lightning map HTML file not found at $LIGHTNING_MAP_FILE"
  fi

  if [ -f "$DAILY_HTML_FILE" ]; then
    aws s3 cp "$DAILY_HTML_FILE" "${S3_BUCKET_PATH}/out/forecasts/" --acl "public-read"
  else
    echo "Warning: Daily HTML file not found at $DAILY_HTML_FILE"
  fi
fi

echo "Hourly lightning map generation complete."
