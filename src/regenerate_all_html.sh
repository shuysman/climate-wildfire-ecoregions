#!/usr/bin/env bash
# Regenerate HTML dashboards for all enabled ecoregions
# This is useful for updating dashboards after template changes without re-running forecasts

set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)
cd "$PROJECT_DIR"

TODAY=$(date +%Y-%m-%d)

echo "========================================="
echo "HTML Dashboard Regeneration"
echo "========================================="
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

  echo "--- Running in cloud mode: Syncing existing forecasts from S3 ---"

  # Sync the entire forecasts output directory (contains all ecoregion outputs)
  echo "Syncing existing forecast outputs..."
  aws s3 sync "${S3_BUCKET_PATH}/out/forecasts/" /app/out/forecasts/ --exclude "*.nc" || echo "Info: No existing forecasts found"

  # Sync config (needed to read ecoregions)
  echo "Syncing config..."
  aws s3 sync "${S3_BUCKET_PATH}/config/" /app/config/ || echo "Warning: Config not found in S3"

else
  echo "--- Running in local mode: Skipping S3 sync ---"
fi

# ============================================================================
# GET ENABLED ECOREGIONS
# ============================================================================

echo ""
echo "Discovering enabled ecoregions from config..."

# Check if yq is available
if ! command -v yq &> /dev/null; then
  echo "Error: yq not found. Install with: apt-get install yq" >&2
  exit 1
fi

# Get all enabled ecoregions
ENABLED_ECOREGIONS=$(yq '.ecoregions[] | select(.enabled == true) | .name_clean' config/ecoregions.yaml 2>/dev/null | tr '\n' ' ' | xargs)

if [ -z "$ENABLED_ECOREGIONS" ]; then
  echo "Error: No enabled ecoregions found in config/ecoregions.yaml" >&2
  exit 1
fi

echo "Enabled ecoregions: $ENABLED_ECOREGIONS"
echo ""

# ============================================================================
# REGENERATE HTML FOR EACH ECOREGION
# ============================================================================

SUCCESS_COUNT=0
FAIL_COUNT=0

# Save and set IFS to space for proper iteration
OLD_IFS="$IFS"
IFS=' '

for ECOREGION in $ENABLED_ECOREGIONS; do
  echo "========================================="
  echo "Regenerating HTML for: $ECOREGION"
  echo "========================================="

  if bash "$PROJECT_DIR/src/generate_daily_html.sh" "$ECOREGION"; then
    echo "✓ Successfully regenerated HTML for $ECOREGION"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "✗ Failed to regenerate HTML for $ECOREGION" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo ""
done

# Restore IFS
IFS="$OLD_IFS"

# ============================================================================
# REGENERATE INDEX PAGE
# ============================================================================

echo "========================================="
echo "Regenerating index landing page..."
echo "========================================="

if bash "$PROJECT_DIR/src/generate_index_html.sh"; then
  echo "✓ Successfully regenerated index page"
else
  echo "✗ Failed to regenerate index page" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ============================================================================
# S3 POST-FLIGHT (Cloud mode only)
# ============================================================================

if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  echo ""
  echo "--- Running in cloud mode: Syncing HTML to S3 ---"

  # Sync all HTML files back to S3
  echo "Syncing HTML dashboards to S3..."

  # Set IFS for proper iteration
  OLD_IFS="$IFS"
  IFS=' '

  for ECOREGION in $ENABLED_ECOREGIONS; do
    echo "Syncing HTML for: ${ECOREGION}"
    aws s3 cp "/app/out/forecasts/${ECOREGION}/daily_forecast.html" \
      "${S3_BUCKET_PATH}/out/forecasts/${ECOREGION}/daily_forecast.html" \
      --acl "public-read" || echo "Warning: Failed to sync ${ECOREGION} HTML"
  done

  # Restore IFS
  IFS="$OLD_IFS"

  # Sync index page
  echo "Syncing index page to S3..."
  aws s3 cp "/app/out/forecasts/index.html" \
    "${S3_BUCKET_PATH}/out/forecasts/index.html" \
    --acl "public-read" || echo "Warning: Failed to sync index page"

  echo "S3 sync complete."
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "========================================="
echo "HTML Regeneration Summary"
echo "========================================="
echo "Ecoregions processed: $((SUCCESS_COUNT + FAIL_COUNT))"
echo "Success: $SUCCESS_COUNT"
echo "Failed:  $FAIL_COUNT"
echo "========================================="

if [ $FAIL_COUNT -gt 0 ]; then
  echo "Warning: Some HTML regenerations failed." >&2
  exit 1
fi

echo "All HTML dashboards regenerated successfully!"
exit 0
