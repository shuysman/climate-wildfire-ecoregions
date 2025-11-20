#!/usr/bin/env bash
# Download CFSv2 forecast data for all variables needed by a specific ecoregion
# Reads config/ecoregions.yaml to determine which variables to download
# Usage: ./update_forecasts_for_ecoregion.sh <ecoregion_name_clean>
# Example: ./update_forecasts_for_ecoregion.sh mojave_basin_and_range

set -euo pipefail
IFS=$'\n\t'

# Check that an ecoregion argument was provided
if [ $# -ne 1 ]; then
  echo "Error: Ecoregion name required" >&2
  echo "Usage: $0 <ecoregion_name_clean>" >&2
  echo "Example: $0 mojave_basin_and_range" >&2
  exit 1
fi

ECOREGION=$1

# Get the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)
cd "$PROJECT_DIR"

# Validate that yq is available
if ! command -v yq &> /dev/null; then
  echo "Error: yq not found. Install with: apt-get install yq" >&2
  exit 1
fi

echo "========================================="
echo "Downloading forecast data for: ${ECOREGION}"
echo "========================================="

# Parse the ecoregion config to find required variables
# Use -r flag for raw output (strips quotes from strings)
FOREST_VAR=$(yq -r ".ecoregions[] | select(.name_clean == \"$ECOREGION\") | .cover_types.forest.gridmet_varname" config/ecoregions.yaml 2>/dev/null)
NON_FOREST_VAR=$(yq -r ".ecoregions[] | select(.name_clean == \"$ECOREGION\") | .cover_types.non_forest.gridmet_varname" config/ecoregions.yaml 2>/dev/null)

# Collect unique variables to download
declare -A VARIABLES_TO_DOWNLOAD

if [ "$FOREST_VAR" != "null" ] && [ -n "$FOREST_VAR" ]; then
  VARIABLES_TO_DOWNLOAD["$FOREST_VAR"]=1
  echo "Forest uses: $FOREST_VAR"
fi

if [ "$NON_FOREST_VAR" != "null" ] && [ -n "$NON_FOREST_VAR" ]; then
  VARIABLES_TO_DOWNLOAD["$NON_FOREST_VAR"]=1
  echo "Non-forest uses: $NON_FOREST_VAR"
fi

if [ ${#VARIABLES_TO_DOWNLOAD[@]} -eq 0 ]; then
  echo "Error: No variables found for ecoregion '$ECOREGION'" >&2
  exit 1
fi

# Special handling for GDD_0 - requires tmax and tmin
if [[ -v VARIABLES_TO_DOWNLOAD["gdd_0"] ]]; then
  echo "GDD_0 detected - will download tmmx and tmmn"
  unset VARIABLES_TO_DOWNLOAD["gdd_0"]
  VARIABLES_TO_DOWNLOAD["tmmx"]=1
  VARIABLES_TO_DOWNLOAD["tmmn"]=1
fi

# Download each unique variable
echo "========================================="
echo "Variables to download: ${!VARIABLES_TO_DOWNLOAD[@]}"
echo "========================================="

for VAR in "${!VARIABLES_TO_DOWNLOAD[@]}"; do
  echo ""
  echo "--- Downloading $VAR ---"
  if ! bash src/operational/data_update/update_rotate_forecast_variable.sh "$VAR"; then
    echo "ERROR: Failed to download $VAR" >&2
    exit 1
  fi
  echo "✓ $VAR download complete"
done

echo ""
echo "========================================="
echo "All forecast downloads complete for ${ECOREGION}!"
echo "========================================="
