#!/usr/bin/env bash
# Generic script to download and rotate CFSv2 forecast for any variable
# Handles both aggregated files (like VPD) and ensemble files (like FM1000)
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
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [$VARIABLE] $1" | tee -a "$LOG_FILE"
}

cleanup() {
  # Ensure temporary files are removed on script exit
  rm -f "$TEMP_FILENAME"
  rm -rf ./ensemble_temp_${VARIABLE}/

  # --- S3 Post-flight (only in cloud mode) ---
  if [ "${ENVIRONMENT:-local}" = "cloud" ]; then
    echo "--- Running in cloud mode: Syncing results to S3 for ${VARIABLE} ---"
    aws s3 sync "$FORECAST_DATA_DIR" "${S3_BUCKET_PATH}/data/forecasts/${VARIABLE}/"
    aws s3 sync "$LOG_DIR" "${S3_BUCKET_PATH}/log/"
  fi
}

# Function to check if a variable uses ensemble files
uses_ensemble_format() {
  local var=$1
  # VPD has aggregated daily files; FM1000, FM100, etc. use ensemble format
  if [[ "$var" == "vpd" ]]; then
    return 1  # false - uses aggregated format
  else
    return 0  # true - uses ensemble format
  fi
}

# Function to download and average ensemble members for a given day
download_ensemble_average() {
  local day=$1
  local output_file=$2

  log "Downloading ensemble members for day $day..."

  # Create temporary directory for ensemble files
  local ensemble_dir="./ensemble_temp_${VARIABLE}_${day}"
  mkdir -p "$ensemble_dir"

  # Forecast hours and ensemble members
  local hours=("00" "06" "12" "18")
  local members=("1" "2" "3" "4")

  local download_count=0
  local ensemble_files=()

  # Download all ensemble members
  for hour in "${hours[@]}"; do
    for member in "${members[@]}"; do
      local ensemble_file="${ensemble_dir}/cfsv2_metdata_forecast_${VARIABLE}_daily_${hour}_${member}_${day}.nc"
      local ensemble_url="${BASE_URL}/cfsv2_metdata_forecast_${VARIABLE}_daily_${hour}_${member}_${day}.nc"

      if wget -q "$ensemble_url" -O "$ensemble_file" 2>/dev/null; then
        ensemble_files+=("$ensemble_file")
        ((download_count++))
      else
        log "Warning: Failed to download ${hour}_${member}_${day}"
      fi
    done
  done

  if [ $download_count -eq 0 ]; then
    log "ERROR: No ensemble files could be downloaded for day $day"
    rm -rf "$ensemble_dir"
    return 1
  fi

  log "Successfully downloaded $download_count ensemble members for day $day"

  # Check if NCO tools are available
  if ! command -v ncea &> /dev/null; then
    log "ERROR: NCO tools (ncea) not found. Cannot compute ensemble average."
    log "Install with: apt-get install nco (Ubuntu) or conda install -c conda-forge nco"
    rm -rf "$ensemble_dir"
    return 1
  fi

  # Compute ensemble mean using NCO's ensemble averager
  log "Computing ensemble mean from $download_count members..."
  ncea -O "${ensemble_files[@]}" "$output_file" 2>&1 | tee -a "$LOG_FILE"

  if [ $? -eq 0 ] && [ -f "$output_file" ]; then
    log "Successfully created ensemble mean: $output_file"
    rm -rf "$ensemble_dir"
    return 0
  else
    log "ERROR: Failed to create ensemble mean"
    rm -rf "$ensemble_dir"
    return 1
  fi
}

# --- Main Logic ---

# Register the cleanup function to run when the script exits
trap cleanup EXIT

# Check if variable uses ensemble format
if uses_ensemble_format "$VARIABLE"; then
  log "Variable $VARIABLE uses ensemble format - will compute ensemble means"

  # If there's no existing forecast, download and create ensemble mean
  if [[ ! -f "$TODAY_FILENAME" ]]; then
    log "No existing forecast file. Downloading ensemble members for day 0..."
    if download_ensemble_average 0 "$TODAY_FILENAME"; then
      log "Initial ensemble mean created successfully."
      exit 0
    else
      log "ERROR: Initial ensemble download failed."
      exit 1
    fi
  fi

  log "Starting forecast update check for ensemble data..."

  # Get the checksum of the current file to compare against
  OLD_CHECKSUM=$(sha256sum "$TODAY_FILENAME" | awk '{print $1}')

  log "Downloading new ensemble members to check for updates..."

  # Download and create new ensemble mean
  if ! download_ensemble_average 0 "$TEMP_FILENAME"; then
    log "ERROR: Failed to download new ensemble data. Keeping existing forecast."
    exit 1
  fi

  # Get the checksum of the new file
  NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

  # Compare checksums
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

else
  # Original aggregated file download logic for VPD
  log "Variable $VARIABLE uses aggregated format"

  FORECAST_URL="${BASE_URL}/cfsv2_metdata_forecast_${VARIABLE}_daily.nc"

  # If there's no existing forecast, just download and exit
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

  # Get the checksum of the current file to compare against
  OLD_CHECKSUM=$(sha256sum "$TODAY_FILENAME" | awk '{print $1}')

  log "Downloading new forecast to temporary file."

  # Download the new file to a temporary location
  if ! wget -q "$FORECAST_URL" -O "$TEMP_FILENAME"; then
    log "ERROR: Download failed. Keeping existing forecast."
    exit 1
  fi

  # Get the checksum of the new file
  NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

  # Compare checksums
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
fi
