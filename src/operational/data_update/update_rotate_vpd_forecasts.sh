#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the project directory (go up 3 levels: data_update -> operational -> src -> project_root)
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)

# --- S3 Pre-flight (only in cloud mode) ---
if [ "${ENVIRONMENT}" = "cloud" ]; then
  if [ -z "${S3_BUCKET_PATH}" ]; then
    echo "Error: S3_BUCKET_PATH environment variable must be set in cloud mode." >&2
    exit 1
  fi
  echo "--- Running in cloud mode: Syncing existing data from S3 ---"
  aws s3 sync "${S3_BUCKET_PATH}/data/vpd/" "$PROJECT_DIR/data/vpd/"
fi

# --- Configuration ---
VPD_DATA_DIR="$PROJECT_DIR/data/vpd/"
LOG_DIR="$PROJECT_DIR/log"
LOG_FILE="$LOG_DIR/vpd.log"
VPD_DATA_URL="http://thredds.northwestknowledge.net:8080/thredds/fileServer/NWCSC_INTEGRATED_SCENARIOS_ALL_CLIMATE/cfsv2_metdata_90day/cfsv2_metdata_forecast_vpd_daily.nc"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# --- File Paths ---
# Ensure we are in the correct directory to avoid path issues
cd "$VPD_DATA_DIR"

TODAY_FILENAME="cfsv2_metdata_forecast_vpd_daily_0.nc"
Tminus1_FILENAME="cfsv2_metdata_forecast_vpd_daily_1.nc"
Tminus2_FILENAME="cfsv2_metdata_forecast_vpd_daily_2.nc"
TEMP_FILENAME="cfsv2_metdata_forecast_vpd_daily.nc.tmp"

# --- Functions ---
log() {
  # Appends a timestamped message to the log file
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

cleanup() {
  # Ensure the temporary file is removed on script exit
  rm -f "$TEMP_FILENAME"

  # --- S3 Post-flight (only in cloud mode) ---
  if [ "${ENVIRONMENT}" = "cloud" ]; then
    echo "--- Running in cloud mode: Syncing results to S3 ---"
    aws s3 sync "$VPD_DATA_DIR" "${S3_BUCKET_PATH}/data/vpd/"
    aws s3 sync "$LOG_DIR" "${S3_BUCKET_PATH}/log/"
  fi
}


# --- Main Logic ---

# Register the cleanup function to run when the script exits
trap cleanup EXIT

# If there's no existing forecast, just download and exit.
if [[ ! -f "$TODAY_FILENAME" ]]; then
  log "No existing forecast file. Downloading for the first time."
  if wget -q "$VPD_DATA_URL" -O "$TODAY_FILENAME"; then
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
if ! wget -q "$VPD_DATA_URL" -O "$TEMP_FILENAME"; then
    log "ERROR: Download failed."
    exit 1 # Exit with failure, let Step Functions handle retry
fi

# Calculate the checksum of the newly downloaded file.
NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

# Compare checksums. If they are different, the forecast is new.
if [[ "$NEW_CHECKSUM" != "$OLD_CHECKSUM" ]]; then
  log "New forecast data found. Rotating files."

  # 1. Rotate forecast files. Delete the oldest one.
  rm -f "$Tminus2_FILENAME"
  mv "$Tminus1_FILENAME" "$Tminus2_FILENAME"
  mv "$TODAY_FILENAME" "$Tminus1_FILENAME"

  # 2. Promote the new file from its temporary location.
  mv "$TEMP_FILENAME" "$TODAY_FILENAME"

  log "Forecast update and rotation successful."
  exit 0 # Success!
else
  log "No new data found. File checksums match. Exiting with failure to signal retry."
  exit 1 # Exit with failure, let Step Functions handle retry
fi
