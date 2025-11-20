#!/usr/bin/env bash
# Discovers required forecast variables from config and downloads them
# This script replaces the single-variable update_rotate_vpd_forecasts.sh

set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)
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

# Download each required variable
SUCCESS_COUNT=0
FAIL_COUNT=0

# Temporarily reset IFS to split on spaces
OLD_IFS="$IFS"
IFS=' '

for VAR in $REQUIRED_VARS; do
  echo "========================================="
  echo "Downloading $VAR forecasts..."
  echo "========================================="

  if bash "$PROJECT_DIR/src/update_rotate_forecast_variable.sh" "$VAR"; then
    echo "✓ Successfully updated $VAR forecasts"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
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
  exit 1
fi

echo "All forecast variables updated successfully!"
exit 0
