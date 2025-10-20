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
  echo "--- Running in cloud mode: Syncing output to S3 ---"
  aws s3 sync /app/out ${S3_BUCKET_PATH}/out
fi

echo "Daily forecast generation complete."
echo "$(date)"
