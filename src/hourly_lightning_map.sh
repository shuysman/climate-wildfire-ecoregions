#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ "${ENVIRONMENT}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Syncing data from S3 ---"
  aws s3 sync "${S3_BUCKET_PATH}/out" /app/out
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
  echo "--- Running in cloud mode: Syncing output to S3 ---"
  aws s3 sync /app/out ${S3_BUCKET_PATH}/out
fi

echo "Hourly lightning map generation complete."
