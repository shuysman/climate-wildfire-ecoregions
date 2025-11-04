#!/usr/bin/env bash
# Generic script to download and rotate CFSv2 forecast for any variable
# Usage: ./update_rotate_forecast_variable.sh <variable>
# Example: ./update_rotate_forecast_variable.sh vpd

set -euo pipefail
IFS=$'\n\t'

# Check that a variable argument was provided
if [ $# -ne 1 ]; then
  echo "Error: Variable name required" >&2
  echo "Usage: $0 <variable>" >&2
  echo "Example: $0 vpd" >&2
  exit 1
fi

VARIABLE=$1

# Get the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. &> /dev/null && pwd)

# --- S3 Pre-flight (only in cloud mode) ---
if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH:-}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Syncing existing data from S3 for ${VARIABLE} ---"
  aws s3 sync "${S3_BUCKET_PATH}/data/forecasts/${VARIABLE}/" "$PROJECT_DIR/data/forecasts/${VARIABLE}/" || true
fi

# --- Configuration ---
FORECAST_DATA_DIR="$PROJECT_DIR/data/forecasts/${VARIABLE}/"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/${VARIABLE}_forecast.log"
BASE_URL="http://thredds.northwestknowledge.net:8080/thredds/fileServer/NWCSC_INTEGRATED_SCENARIOS_ALL_CLIMATE/cfsv2_metdata_90day"
FORECAST_URL="${BASE_URL}/cfsv2_metdata_forecast_${VARIABLE}_daily.nc"

# Create directories if they don't exist
mkdir -p "$FORECAST_DATA_DIR"
mkdir -p "$LOG_DIR"

# --- File Paths ---
cd "$FORECAST_DATA_DIR"

TODAY_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_0.nc"
Tminus1_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_1.nc"
Tminus2_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_2.nc"
TEMP_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily.nc.tmp"

# --- Functions ---
log() {
  # Appends a timestamped message to the log file
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [$VARIABLE] $1" | tee -a "$LOG_FILE"
}

cleanup() {
  # Ensure the temporary file is removed on script exit
  rm -f "$TEMP_FILENAME"

  # --- S3 Post-flight (only in cloud mode) ---
  if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
    echo "--- Running in cloud mode: Syncing results to S3 for ${VARIABLE} ---"
    aws s3 sync "$FORECAST_DATA_DIR" "${S3_BUCKET_PATH}/data/forecasts/${VARIABLE}/"
    aws s3 sync "$LOG_DIR" "${S3_BUCKET_PATH}/log/"
  fi
}

# --- Main Logic ---

# Register the cleanup function to run when the script exits
trap cleanup EXIT

# If there's no existing forecast, just download and exit.
if [[ ! -f "$TODAY_FILENAME" ]]; then
  log "No existing forecast file. Downloading for the first time."
  if wget -q "$FORECAST_URL" -O "$TODAY_FILENAME"; then
    log "Initial download successful."
    exit 0
  else
    log "ERROR: Initial download failed."
    exit 1
  fi
fi

log "Starting forecast update check."

# Get the checksum of the current file to compare against.
OLD_CHECKSUM=$(sha256sum "$TODAY_FILENAME" | awk '{print $1}')

log "Downloading new forecast to temporary file."

# Download the new file to a temporary location.
if ! wget -q "$FORECAST_URL" -O "$TEMP_FILENAME"; then
  log "ERROR: Download failed. Keeping existing forecast."
  exit 1
fi

# Get the checksum of the new file.
NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

# Compare checksums.
if [[ "$OLD_CHECKSUM" == "$NEW_CHECKSUM" ]]; then
  log "No update detected. Forecast is unchanged."
  exit 0
fi

log "Update detected! Rotating forecast files."

# Rotate files: T-1 becomes T-2, T becomes T-1, new becomes T
if [[ -f "$Tminus1_FILENAME" ]]; then
  mv "$Tminus1_FILENAME" "$Tminus2_FILENAME"
  log "Rotated T-1 to T-2."
fi

if [[ -f "$TODAY_FILENAME" ]]; then
  mv "$TODAY_FILENAME" "$Tminus1_FILENAME"
  log "Rotated T to T-1."
fi

mv "$TEMP_FILENAME" "$TODAY_FILENAME"
log "New forecast is now active."

log "Forecast update complete."
exit 0
