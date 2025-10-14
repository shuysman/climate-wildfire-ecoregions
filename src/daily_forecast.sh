#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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

echo "Daily forecast generation complete."
echo "$(date)"
