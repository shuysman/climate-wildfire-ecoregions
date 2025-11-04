#!/usr/bin/env bash
# Daily forecast generation script for a single ecoregion
# Accepts ECOREGION environment variable to specify which ecoregion to process

set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIGURATION
# ============================================================================

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)
cd "$PROJECT_DIR"

# Get ecoregion from environment variable (default to middle_rockies for backward compat)
ECOREGION=${ECOREGION:-middle_rockies}
TODAY=$(date +%Y-%m-%d)

echo "========================================="
echo "Daily Forecast Generation"
echo "========================================="
echo "Ecoregion: $ECOREGION"
echo "Date: $TODAY"
echo "Environment: ${ENVIRONMENT:-local}"
echo "========================================="

# ============================================================================
# S3 PRE-FLIGHT (Cloud mode only)
# ============================================================================

if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH:-}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi

  echo "--- Running in cloud mode: Syncing data from S3 ---"

  # Sync static data needed for processing (eCDF models, cover rasters, boundaries)
  echo "Syncing static data (ecdf, classified_cover, boundaries)..."
  aws s3 sync "${S3_BUCKET_PATH}/data/ecdf/" /app/data/ecdf/ || echo "Warning: ecdf sync failed"
  aws s3 sync "${S3_BUCKET_PATH}/data/classified_cover/" /app/data/classified_cover/ || echo "Warning: classified_cover sync failed"
  aws s3 sync "${S3_BUCKET_PATH}/data/us_eco_l3/" /app/data/us_eco_l3/ || echo "Warning: us_eco_l3 sync failed"

  # Sync forecast data (downloaded by update task)
  echo "Syncing forecast data..."
  aws s3 sync "${S3_BUCKET_PATH}/data/forecasts/" /app/data/forecasts/ || echo "Warning: forecasts sync failed"

  # Sync existing output for this ecoregion (for incremental updates)
  echo "Syncing existing outputs for ${ECOREGION}..."
  aws s3 sync "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/" "/app/out/forecasts/${ECOREGION}/" || echo "Info: No existing outputs for ${ECOREGION}"

  # Sync cache
  aws s3 sync "${S3_BUCKET_PATH}/out/cache/" /app/out/cache/ || echo "Info: No existing cache"
else
  echo "--- Running in local mode: Skipping S3 sync ---"
fi

# ============================================================================
# RUN FORECAST GENERATION
# ============================================================================

echo ""
echo "Starting forecast generation for ${ECOREGION}..."
echo "$(date)"

# Run the map generation script with ecoregion parameter
echo "Step 1: Generating fire danger forecast maps..."
Rscript ./src/map_forecast_danger.R "$ECOREGION"

# Run the threshold plot generation script
echo "Step 2: Generating park threshold plots..."
Rscript ./src/generate_threshold_plots.R "$ECOREGION"

# Generate the daily HTML report
echo "Step 3: Generating daily HTML report..."
./src/generate_daily_html.sh "$ECOREGION"

# Create the Cloud-Optimized GeoTIFF for today for web mapping use
echo "Step 4: Creating Cloud-Optimized GeoTIFF..."
./src/create_cog_for_today.sh "$ECOREGION"

# ============================================================================
# S3 POST-FLIGHT (Cloud mode only)
# ============================================================================

if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  echo ""
  echo "--- Running in cloud mode: Syncing final outputs to S3 ---"

  ECOREGION_OUT_DIR="/app/out/forecasts/${ECOREGION}"
  S3_ECOREGION_OUT_DIR="${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}"

  # Sync the entire ecoregion output directory
  # Exclude NetCDF files (too large, not needed for web display)
  echo "Syncing ${ECOREGION} outputs to S3..."
  aws s3 sync "$ECOREGION_OUT_DIR" "$S3_ECOREGION_OUT_DIR" \
    --exclude "*.nc" \
    --acl "public-read" \
    --delete

  # Sync cache (gridMET historical data)
  CACHE_DIR="/app/out/cache"
  if [ -d "$CACHE_DIR" ]; then
    echo "Syncing cache to S3..."
    aws s3 sync "$CACHE_DIR" "${S3_BUCKET_PATH}/out/cache/" --acl "public-read"
  fi

  echo "S3 sync complete for ${ECOREGION}."
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "========================================="
echo "Daily forecast generation complete!"
echo "========================================="
echo "Ecoregion: $ECOREGION"
echo "Date: $TODAY"
echo "Output directory: out/forecasts/${ECOREGION}/${TODAY}/"
echo "$(date)"
echo "========================================="
