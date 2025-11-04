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

# Check if R and yaml package are available
if ! command -v Rscript &> /dev/null; then
  echo "Error: Rscript not found. R is required to parse config." >&2
  exit 1
fi

# Discover required variables from YAML config
echo "Parsing config/ecoregions.yaml to discover required forecast variables..."

REQUIRED_VARS=$(Rscript -e "
suppressPackageStartupMessages(library(yaml))

config <- tryCatch(
  read_yaml('config/ecoregions.yaml'),
  error = function(e) {
    stop('Failed to read config/ecoregions.yaml: ', e\$message)
  }
)

# Filter to enabled ecoregions only
enabled <- config\$ecoregions[sapply(config\$ecoregions, function(x) isTRUE(x\$enabled))]

if (length(enabled) == 0) {
  stop('No enabled ecoregions found in config')
}

# Extract unique variables from both forest and non-forest cover types
vars <- unique(c(
  sapply(enabled, function(x) x\$cover_types\$forest\$variable),
  sapply(enabled, function(x) x\$cover_types\$non_forest\$variable)
))

# Remove any NAs and print
vars <- vars[!is.na(vars)]
cat(paste(vars, collapse=' '))
")

if [ -z "$REQUIRED_VARS" ]; then
  echo "Error: No forecast variables discovered from config" >&2
  exit 1
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
    ((SUCCESS_COUNT++))
  else
    echo "✗ Failed to update $VAR forecasts" >&2
    ((FAIL_COUNT++))
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
