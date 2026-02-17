#!/usr/bin/env bash
# Discovers required forecast variables from config and downloads them
# This script replaces the single-variable update_rotate_vpd_forecasts.sh

set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)
cd "$PROJECT_DIR"

echo "========================================="
echo "Multi-Variable Forecast Download Script"
echo "========================================="

# Check if yq is available
if ! command -v yq &> /dev/null; then
  echo "Error: yq not found. Install with: apt-get install yq" >&2
  exit 1
fi

# Discover required variables from YAML config
echo "Parsing config/ecoregions.yaml to discover required forecast variables..."

# Extract unique variables from all enabled ecoregions (no error suppression)
REQUIRED_VARS=$(yq '.ecoregions[] | select(.enabled == true) | .cover_types | to_entries[] | .value.gridmet_varname' config/ecoregions.yaml | sort -u | tr '\n' ' ' | xargs)

if [ -z "$REQUIRED_VARS" ]; then
  echo "Error: No forecast variables discovered from config. Check config format and yq installation." >&2
  exit 1
fi

# Validate that all variables have non-empty values
for VAR in $REQUIRED_VARS; do
  if [ -z "$VAR" ]; then
    echo "Error: Found empty gridmet_varname in config. Check config/ecoregions.yaml" >&2
    exit 1
  fi
done

# Special handling for GDD_0 - requires tmmx and tmmn instead
if echo "$REQUIRED_VARS" | grep -q "gdd_0"; then
  echo "GDD_0 detected - will download tmmx and tmmn instead"
  REQUIRED_VARS=$(echo "$REQUIRED_VARS" | sed 's/gdd_0/tmmx tmmn/g' | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
fi

echo "Required forecast variables: $REQUIRED_VARS"
echo ""

# --- Identify coupled variable groups ---
# GDD_0 requires tmmx and tmmn with matching date offsets. These must rotate
# atomically to prevent desync from server-side race conditions (one variable
# updating on the THREDDS server before the other).
COUPLED_VARS=""
INDEPENDENT_VARS="$REQUIRED_VARS"

if echo "$REQUIRED_VARS" | grep -qw "tmmx" && echo "$REQUIRED_VARS" | grep -qw "tmmn"; then
  COUPLED_VARS="tmmx tmmn"
  INDEPENDENT_VARS=$(echo "$REQUIRED_VARS" | tr ' ' '\n' | grep -v "^tmmx$" | grep -v "^tmmn$" | tr '\n' ' ' | xargs)
fi

# Helper: perform rotation for a variable from its existing temp file
rotate_forecast_variable() {
  local var=$1
  local dir="$PROJECT_DIR/data/forecasts/${var}"
  local f0="${dir}/cfsv2_metdata_forecast_${var}_daily_0.nc"
  local f1="${dir}/cfsv2_metdata_forecast_${var}_daily_1.nc"
  local f2="${dir}/cfsv2_metdata_forecast_${var}_daily_2.nc"
  local f3="${dir}/cfsv2_metdata_forecast_${var}_daily_3.nc"
  local temp="${dir}/cfsv2_metdata_forecast_${var}_daily.nc.tmp"

  if [[ ! -f "$temp" ]]; then
    echo "  ERROR: No temp file for $var rotation" >&2
    return 1
  fi

  if [[ -f "$f2" ]]; then mv "$f2" "$f3"; fi
  if [[ -f "$f1" ]]; then mv "$f1" "$f2"; fi
  if [[ -f "$f0" ]]; then mv "$f0" "$f1"; fi
  mv "$temp" "$f0"
  echo "  ✓ $var rotated"
}

# Helper: clean up temp file for a variable
cleanup_temp() {
  local var=$1
  rm -f "$PROJECT_DIR/data/forecasts/${var}/cfsv2_metdata_forecast_${var}_daily.nc.tmp"
}

# Download each required variable
# IMPORTANT: Defer S3 sync until ALL variables succeed to prevent over-rotation
# when retries occur due to stale data for some variables
SUCCESS_COUNT=0
FAIL_COUNT=0
DOWNLOADED_VARS=""

# --- Process coupled variables (tmmx/tmmn) with deferred rotation ---
if [ -n "$COUPLED_VARS" ]; then
  echo "========================================="
  echo "Processing coupled variables: $COUPLED_VARS"
  echo "(rotation deferred until both are checked)"
  echo "========================================="
  echo ""

  COUPLED_FAIL=false
  COUPLED_READY_COUNT=0
  COUPLED_TOTAL=0

  OLD_IFS="$IFS"
  IFS=' '
  for VAR in $COUPLED_VARS; do
    COUPLED_TOTAL=$((COUPLED_TOTAL + 1))
    echo "========================================="
    echo "Downloading $VAR forecasts (deferred rotation)..."
    echo "========================================="

    if SKIP_S3_SYNC=true DEFER_ROTATION=true bash "$PROJECT_DIR/src/operational/data_update/update_rotate_forecast_variable.sh" "$VAR"; then
      TEMP_FILE="$PROJECT_DIR/data/forecasts/${VAR}/cfsv2_metdata_forecast_${VAR}_daily.nc.tmp"
      if [ -f "$TEMP_FILE" ]; then
        echo "✓ $VAR: new data ready (rotation deferred)"
        COUPLED_READY_COUNT=$((COUPLED_READY_COUNT + 1))
      else
        echo "✓ $VAR: unchanged (no rotation needed)"
      fi
    else
      echo "✗ Failed to download $VAR forecasts" >&2
      COUPLED_FAIL=true
    fi
    echo ""
  done
  IFS="$OLD_IFS"

  # Decide whether to rotate
  if [ "$COUPLED_FAIL" = "true" ]; then
    echo "ERROR: Coupled variable download failed. Cleaning up temp files." >&2
    OLD_IFS="$IFS"; IFS=' '
    for VAR in $COUPLED_VARS; do cleanup_temp "$VAR"; done
    IFS="$OLD_IFS"
    FAIL_COUNT=$((FAIL_COUNT + COUPLED_TOTAL))
  elif [ "$COUPLED_READY_COUNT" -eq "$COUPLED_TOTAL" ]; then
    # All coupled variables have new data — rotate all together
    echo "All coupled variables have new data. Rotating together..."
    OLD_IFS="$IFS"; IFS=' '
    for VAR in $COUPLED_VARS; do
      rotate_forecast_variable "$VAR"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      DOWNLOADED_VARS="$DOWNLOADED_VARS $VAR"
    done
    IFS="$OLD_IFS"
  elif [ "$COUPLED_READY_COUNT" -eq 0 ]; then
    # None have new data — all unchanged, nothing to do
    echo "All coupled variables unchanged. No rotation needed."
    OLD_IFS="$IFS"; IFS=' '
    for VAR in $COUPLED_VARS; do
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      DOWNLOADED_VARS="$DOWNLOADED_VARS $VAR"
    done
    IFS="$OLD_IFS"
  else
    # Mixed: some have new data, some don't — upstream server mid-update
    echo "WARNING: Coupled variable desync detected!" >&2
    echo "  $COUPLED_READY_COUNT of $COUPLED_TOTAL variables have new data." >&2
    echo "  Upstream server likely mid-update. Discarding new data to trigger retry." >&2
    OLD_IFS="$IFS"; IFS=' '
    for VAR in $COUPLED_VARS; do cleanup_temp "$VAR"; done
    IFS="$OLD_IFS"
    FAIL_COUNT=$((FAIL_COUNT + COUPLED_TOTAL))
  fi
  echo ""
fi

# --- Process independent variables ---
OLD_IFS="$IFS"
IFS=' '

for VAR in $INDEPENDENT_VARS; do
  echo "========================================="
  echo "Downloading $VAR forecasts..."
  echo "========================================="

  # Skip per-variable S3 sync - we'll sync all at once after all succeed
  if SKIP_S3_SYNC=true bash "$PROJECT_DIR/src/operational/data_update/update_rotate_forecast_variable.sh" "$VAR"; then
    echo "✓ Successfully updated $VAR forecasts"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    DOWNLOADED_VARS="$DOWNLOADED_VARS $VAR"
  else
    echo "✗ Failed to update $VAR forecasts" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo ""
done

# Restore original IFS
IFS="$OLD_IFS"

# Summary
echo "========================================="
echo "Download Summary"
echo "========================================="
echo "Success: $SUCCESS_COUNT"
echo "Failed:  $FAIL_COUNT"
echo "========================================="

if [ $FAIL_COUNT -gt 0 ]; then
  echo "Warning: Some forecast downloads failed. Check logs for details." >&2
  echo "S3 sync skipped - no changes uploaded to prevent partial updates." >&2
  exit 1
fi

# --- S3 Sync (only after ALL variables succeed) ---
# This prevents over-rotation: if any variable fails and causes a retry,
# the old (correctly offset) files remain on S3
if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH:-}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi

  echo "========================================="
  echo "Syncing all forecast data to S3..."
  echo "========================================="

  # Reset IFS to split on spaces for the variable list
  IFS=' '
  for VAR in $DOWNLOADED_VARS; do
    echo "Syncing $VAR..."
    aws s3 sync --delete "$PROJECT_DIR/data/forecasts/${VAR}/" "${S3_BUCKET_PATH}/data/forecasts/${VAR}/"
  done

  echo "Syncing logs..."
  aws s3 sync "$PROJECT_DIR/log/" "${S3_BUCKET_PATH}/log/"

  echo "✓ S3 sync complete"
fi

echo "All forecast variables updated successfully!"
exit 0
