#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "Starting hourly lightning map generation..."

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

TODAY_FORECAST_FILE="out/forecasts/fire_danger_forecast_${TODAY}.nc"
YESTERDAY_FORECAST_FILE="out/forecasts/fire_danger_forecast_${YESTERDAY}.nc"

FORECAST_TO_USE=""
FORECAST_STATUS=""
# The date for the forecast data should always be today.
FORECAST_DATE="$TODAY"

if [ -f "$TODAY_FORECAST_FILE" ]; then
  echo "Today's forecast found. Using $TODAY_FORECAST_FILE"
  FORECAST_TO_USE="$TODAY_FORECAST_FILE"
  FORECAST_STATUS="Current"
else
  echo "Today's forecast not found. Falling back to yesterday's forecast: $YESTERDAY_FORECAST_FILE"
  FORECAST_TO_USE="$YESTERDAY_FORECAST_FILE"
  FORECAST_STATUS="Previous Day"
fi

# Run the lightning map generation script, always passing today's date.
Rscript ./src/map_lightning.R "$FORECAST_TO_USE" "$FORECAST_STATUS" "$FORECAST_DATE"

echo "Hourly lightning map generation complete."
