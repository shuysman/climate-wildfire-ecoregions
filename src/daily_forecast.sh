#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ "${ENVIRONMENT}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Syncing data from S3 ---"
  aws s3 sync "${S3_BUCKET_PATH}/data" /app/data
  aws s3 sync "${S3_BUCKET_PATH}/out" /app/out
else
  echo "--- Running in local mode: Skipping S3 sync ---"
fi

echo "Starting daily forecast generation..."
echo "$(date)"

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)

cd $PROJECT_DIR

# Run the update script
#./src/update_rotate_vpd_forecasts.sh

# Run the map generation script
Rscript ./src/map_forecast_danger.R

# Run the threshold plot generation script
Rscript ./src/generate_threshold_plots.R

# Generate the daily HTML report
./src/generate_daily_html.sh

# Create the Cloud-Optimized GeoTIFF for today for web mapping use
./src/create_cog_for_today.sh

if [ "${ENVIRONMENT}" = "cloud" ]; then
  echo "--- Running in cloud mode: Syncing final outputs to S3 ---"
  
  TODAY=$(date +%Y-%m-%d)
  ECOREGION_NAME_CLEAN="middle_rockies"
  FORECAST_DIR="/app/out/forecasts"
  CACHE_DIR="/app/out/cache"
  S3_OUT_DIR="${S3_BUCKET_PATH}/out"

  NC_FILE_PATH="${FORECAST_DIR}/fire_danger_forecast_${TODAY}.nc"
  DAILY_HTML_FILE="${FORECAST_DIR}/daily_forecast.html"
  MAIN_MAP_PNG_PATH="${FORECAST_DIR}/${ECOREGION_NAME_CLEAN}_fire_danger_forecast_${TODAY}.png"
  PARKS_DIR="${FORECAST_DIR}/parks"

  # 1. Copy the main NetCDF file
  if [ -f "$NC_FILE_PATH" ]; then
    aws s3 cp "$NC_FILE_PATH" "${S3_OUT_DIR}/forecasts/"
  else
    echo "Warning: Output NetCDF file not found at $NC_FILE_PATH"
  fi

  # 2. Copy the main HTML file
  if [ -f "$DAILY_HTML_FILE" ]; then
    aws s3 cp "$DAILY_HTML_FILE" "${S3_OUT_DIR}/forecasts/"
  else
    echo "Warning: Daily HTML file not found at $DAILY_HTML_FILE"
  fi
  
  # 3. Copy the main forecast map PNG
  if [ -f "$MAIN_MAP_PNG_PATH" ]; then
    aws s3 cp "$MAIN_MAP_PNG_PATH" "${S3_OUT_DIR}/forecasts/"
  else
    echo "Warning: Main map PNG file not found at $MAIN_MAP_PNG_PATH"
  fi

  # 4. Copy all park-specific plots recursively
  if [ -d "$PARKS_DIR" ]; then
    aws s3 cp "$PARKS_DIR" "${S3_OUT_DIR}/forecasts/parks/" --recursive
  else
    echo "Info: No 'parks' directory found to upload."
  fi

  # 5. Copy the gridMET cache
  if [ -d "$CACHE_DIR" ]; then
    aws s3 cp "$CACHE_DIR" "${S3_OUT_DIR}/cache/" --recursive
  else
    echo "Info: No 'cache' directory found to upload."
  fi
fi

echo "Daily forecast generation complete."
echo "$(date)"
