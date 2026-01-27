#!/usr/bin/env bash
# Daily forecast generation script for a single ecoregion
# Accepts ECOREGION environment variable to specify which ecoregion to process

set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# CONFIGURATION
# ============================================================================

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)
cd "$PROJECT_DIR"

# Get ecoregion from environment variable (default to middle_rockies for backward compat)
ECOREGION=${ECOREGION:-middle_rockies}
TODAY=$(date +%Y-%m-%d)

# Validate that yq is available
if ! command -v yq &> /dev/null; then
  echo "Error: yq not found. Install with: apt-get install yq" >&2
  exit 1
fi

# Validate that ecoregion exists and is enabled in config
ECOREGION_ENABLED=$(yq ".ecoregions[] | select(.name_clean == \"$ECOREGION\") | .enabled" config/ecoregions.yaml 2>/dev/null)

if [ -z "$ECOREGION_ENABLED" ]; then
  echo "Error: Ecoregion '$ECOREGION' not found in config/ecoregions.yaml" >&2
  echo "Available ecoregions:" >&2
  yq '.ecoregions[] | .name_clean' config/ecoregions.yaml 2>/dev/null | sed 's/^/  - /' >&2
  exit 1
fi

if [ "$ECOREGION_ENABLED" != "true" ]; then
  echo "Error: Ecoregion '$ECOREGION' is not enabled in config/ecoregions.yaml" >&2
  echo "Set 'enabled: true' for this ecoregion to process it." >&2
  exit 1
fi

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

  # Sync CRITICAL static data (required for processing - fail if missing)
  echo "Syncing critical data (eCDF models, classified cover, boundaries)..."

  if ! aws s3 sync "${S3_BUCKET_PATH}/data/ecdf/" /app/data/ecdf/; then
    echo "Error: Failed to sync critical eCDF models from S3" >&2
    exit 1
  fi

  if ! aws s3 sync "${S3_BUCKET_PATH}/data/classified_cover/" /app/data/classified_cover/; then
    echo "Error: Failed to sync critical classified_cover data from S3" >&2
    exit 1
  fi

  if ! aws s3 sync "${S3_BUCKET_PATH}/data/us_eco_l3/" /app/data/us_eco_l3/; then
    echo "Error: Failed to sync critical ecoregion boundary data from S3" >&2
    exit 1
  fi

  # Sync NPS boundary data (required for park threshold plots)
  echo "Syncing NPS boundary data..."
  if ! aws s3 sync "${S3_BUCKET_PATH}/data/nps_boundary/" /app/data/nps_boundary/; then
    echo "Warning: Failed to sync NPS boundary data from S3. Park analyses will be skipped." >&2
    # Don't exit - park analyses are optional
  fi

  # Sync forecast data (downloaded by update task - critical)
  echo "Syncing forecast data..."
  if ! aws s3 sync "${S3_BUCKET_PATH}/data/forecasts/" /app/data/forecasts/; then
    echo "Error: Failed to sync forecast data from S3" >&2
    exit 1
  fi

  # Sync recent outputs for this ecoregion (today + yesterday for fallback)
  # Only sync last 2 days to minimize bandwidth
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
  echo "Syncing recent outputs for ${ECOREGION} (today and yesterday for fallback)..."
  aws s3 sync "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/${TODAY}/" "/app/out/forecasts/${ECOREGION}/${TODAY}/" 2>/dev/null || echo "Info: No output for ${TODAY}"
  aws s3 sync "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/${YESTERDAY}/" "/app/out/forecasts/${ECOREGION}/${YESTERDAY}/" 2>/dev/null || echo "Info: No output for ${YESTERDAY}"

  # Sync the daily_forecast.html file (landing page for this ecoregion)
  aws s3 cp "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/daily_forecast.html" "/app/out/forecasts/${ECOREGION}/daily_forecast.html" 2>/dev/null || echo "Info: No existing dashboard HTML"

  # Sync cache (optional - helpful for climateR caching)
  echo "Syncing cache..."
  aws s3 sync "${S3_BUCKET_PATH}/out/cache/" /app/out/cache/ 2>/dev/null || echo "Info: No existing cache"
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
Rscript ./src/operational/forecast/map_forecast_danger.R "$ECOREGION"

# Validate the generated forecast
echo "Step 2: Validating forecast..."
if ! Rscript ./src/operational/validation/validate_forecast.R "$ECOREGION"; then
  VALIDATION_EXIT_CODE=$?
  if [ $VALIDATION_EXIT_CODE -eq 1 ]; then
    echo "ERROR: Forecast validation FAILED. Do not publish this forecast." >&2
    exit 1
  elif [ $VALIDATION_EXIT_CODE -eq 2 ]; then
    echo "WARNING: Forecast validation detected anomalies. Review before publishing." >&2
    # Continue anyway, but log the warning
  fi
fi

# Run the threshold plot generation script
echo "Step 3: Generating park threshold plots..."
Rscript ./src/operational/visualization/generate_threshold_plots.R "$ECOREGION"

# Generate the daily HTML report
echo "Step 4: Generating daily HTML report..."
./src/operational/html_generation/generate_daily_html.sh "$ECOREGION"

# Create the Cloud-Optimized GeoTIFF for today for web mapping use
echo "Step 5: Creating Cloud-Optimized GeoTIFF..."
./src/operational/visualization/create_cog_for_today.sh "$ECOREGION"

# ============================================================================
# S3 POST-FLIGHT (Cloud mode only)
# ============================================================================

if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  echo ""
  echo "--- Running in cloud mode: Syncing final outputs to S3 ---"

  ECOREGION_OUT_DIR="/app/out/forecasts/${ECOREGION}"
  S3_ECOREGION_OUT_DIR="${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}"

  # Sync only today's date directory (preserves historical forecasts in S3)
  echo "Syncing ${ECOREGION}/${TODAY} outputs to S3..."
  aws s3 sync "$ECOREGION_OUT_DIR/${TODAY}" "$S3_ECOREGION_OUT_DIR/${TODAY}" \
    --acl "public-read"

  # Sync the landing page HTML (lives at ecoregion root level)
  echo "Syncing dashboard HTML..."
  aws s3 cp "$ECOREGION_OUT_DIR/daily_forecast.html" "$S3_ECOREGION_OUT_DIR/daily_forecast.html" \
    --acl "public-read"

  # Sync cache (gridMET historical data)
  CACHE_DIR="/app/out/cache"
  if [ -d "$CACHE_DIR" ]; then
    echo "Syncing cache to S3..."
    aws s3 sync "$CACHE_DIR" "${S3_BUCKET_PATH}/out/cache/" --acl "public-read"
  fi

  echo "S3 sync complete for ${ECOREGION}."

  # Archive old forecasts, keeping only 2 most recent
  bash ./src/operational/pipeline/archive_old_forecasts.sh || echo "Warning: forecast archival failed"
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
