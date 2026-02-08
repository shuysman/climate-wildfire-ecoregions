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

  # Sync all recent outputs for this ecoregion (archive keeps only 2-3 date dirs, so bandwidth is minimal)
  echo "Syncing recent outputs for ${ECOREGION}..."
  aws s3 sync "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/" "/app/out/forecasts/${ECOREGION}/" 2>/dev/null || echo "Info: No existing outputs for ${ECOREGION}"

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
FORECAST_FAILED=false
if ! Rscript ./src/operational/forecast/map_forecast_danger.R "$ECOREGION"; then
  echo "WARNING: Forecast generation failed for ${ECOREGION}. Will show most recent available forecast." >&2
  FORECAST_FAILED=true
fi

if [ "$FORECAST_FAILED" = false ]; then
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

  # Create the Cloud-Optimized GeoTIFF for today for web mapping use
  echo "Step 4: Creating Cloud-Optimized GeoTIFF..."
  ./src/operational/visualization/create_cog_for_today.sh "$ECOREGION"
else
  echo "Skipping validation, threshold plots, and COG generation (forecast failed)."

  # Write warning file at ecoregion root so the HTML generator shows a banner.
  # The R script may have already written this (e.g., on gridMET failure), but if it
  # failed for another reason (validation, missing data, etc.) we need to catch that too.
  WARNING_FILE="out/forecasts/${ECOREGION}/FORECAST_UNAVAILABLE_WARNING.txt"
  mkdir -p "out/forecasts/${ECOREGION}"
  cat > "$WARNING_FILE" <<EOF
FORECAST UNAVAILABLE WARNING
============================
Generated: $(date)
Forecast generation failed for ${ECOREGION} on ${TODAY}.
The most recent available forecast will be shown until the issue is resolved.
EOF

  # Remove the empty date directory created by map_forecast_danger.R before it failed.
  # Leaving it would cause the archive script to count it as a real forecast and evict
  # an older valid one, and confuse other scripts (e.g., lightning maps).
  TODAY_OUT_DIR="out/forecasts/${ECOREGION}/${TODAY}"
  if [ -d "$TODAY_OUT_DIR" ] && [ ! -f "$TODAY_OUT_DIR/fire_danger_forecast.png" ]; then
    echo "Removing empty forecast directory: ${TODAY_OUT_DIR}"
    rm -rf "$TODAY_OUT_DIR"
  fi
fi

# ALWAYS generate HTML (shows most recent available forecast + warning if today's failed)
echo "Step 5: Generating daily HTML report..."
Rscript ./src/operational/html_generation/generate_daily_html.R "$ECOREGION"

# ============================================================================
# S3 POST-FLIGHT (Cloud mode only)
# ============================================================================

if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  echo ""
  echo "--- Running in cloud mode: Syncing final outputs to S3 ---"

  ECOREGION_OUT_DIR="/app/out/forecasts/${ECOREGION}"
  S3_ECOREGION_OUT_DIR="${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}"

  # Sync today's date directory if it exists (preserves historical forecasts in S3)
  if [ -d "$ECOREGION_OUT_DIR/${TODAY}" ]; then
    echo "Syncing ${ECOREGION}/${TODAY} outputs to S3..."
    aws s3 sync "$ECOREGION_OUT_DIR/${TODAY}" "$S3_ECOREGION_OUT_DIR/${TODAY}" \
      --acl "public-read"
  fi

  # Sync ecoregion-level files (dashboard HTML + warning file)
  echo "Syncing dashboard HTML and warning files..."
  if [ -f "$ECOREGION_OUT_DIR/daily_forecast.html" ]; then
    aws s3 cp "$ECOREGION_OUT_DIR/daily_forecast.html" "$S3_ECOREGION_OUT_DIR/daily_forecast.html" --acl "public-read"
  fi
  if [ -f "$ECOREGION_OUT_DIR/FORECAST_UNAVAILABLE_WARNING.txt" ]; then
    aws s3 cp "$ECOREGION_OUT_DIR/FORECAST_UNAVAILABLE_WARNING.txt" "$S3_ECOREGION_OUT_DIR/FORECAST_UNAVAILABLE_WARNING.txt" --acl "public-read"
  else
    # Warning file was cleared (successful forecast) — remove from S3 too
    aws s3 rm "$S3_ECOREGION_OUT_DIR/FORECAST_UNAVAILABLE_WARNING.txt" 2>/dev/null || true
  fi

  # Always sync cache (gridMET historical data) so fresh downloads survive failures
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
