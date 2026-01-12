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

# Get the project directory (go up 3 levels: data_update -> operational -> src -> project_root)
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../../ &> /dev/null && pwd)

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

# Time-based cutoff for accepting stale data (UTC hour, 0-23)
# Before this hour: exit 1 on stale data to trigger Step Functions retry
# After this hour: accept stale data and proceed with warning
# Default 18:00 UTC (~11:00 AM Mountain, after typical ~17:06 UTC update)
STALE_DATA_CUTOFF_HOUR="${STALE_DATA_CUTOFF_HOUR:-18}"

# Create directories if they don't exist
mkdir -p "$FORECAST_DATA_DIR"
mkdir -p "$LOG_DIR"

# --- File Paths ---
cd "$FORECAST_DATA_DIR"

TODAY_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_0.nc"
Tminus1_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_1.nc"
Tminus2_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily_2.nc"
TEMP_FILENAME="cfsv2_metdata_forecast_${VARIABLE}_daily.nc.tmp"
STALE_WARNING_FILE="STALE_DATA_WARNING.txt"

# --- Functions ---
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [$VARIABLE] $1" | tee -a "$LOG_FILE" >&2
}

# Check if current time is past the stale data cutoff
# Returns 0 (true) if past cutoff, 1 (false) if before cutoff
past_stale_cutoff() {
  local current_hour
  current_hour=$(date -u +%H)
  # Remove leading zero for numeric comparison
  current_hour=$((10#$current_hour))

  if [ "$current_hour" -ge "$STALE_DATA_CUTOFF_HOUR" ]; then
    return 0  # true - past cutoff, accept stale data
  else
    return 1  # false - before cutoff, keep retrying
  fi
}

# Handle stale data based on time cutoff
# Returns 0 if we should proceed with stale data, 1 if we should retry
handle_stale_data() {
  local forecast_date=$1

  if past_stale_cutoff; then
    log "Past stale data cutoff (${STALE_DATA_CUTOFF_HOUR}:00 UTC) - accepting stale data"
    create_stale_warning "$forecast_date"
    return 0  # proceed with stale data
  else
    log "Before stale data cutoff (${STALE_DATA_CUTOFF_HOUR}:00 UTC) - will retry for fresh data"
    log "Current time: $(date -u '+%H:%M UTC')"
    return 1  # retry
  fi
}

# Create a stale data warning file and log prominently
create_stale_warning() {
  local forecast_date=$1
  local today
  today=$(date +%Y-%m-%d)

  log "╔════════════════════════════════════════════════════════════════╗"
  log "║ WARNING: USING STALE FORECAST DATA                             ║"
  log "║ Variable: $VARIABLE"
  log "║ Expected forecast start: $today or $(date -d 'tomorrow' +%Y-%m-%d)"
  log "║ Actual forecast start: $forecast_date"
  log "║ Proceeding with existing (previous day's) forecast data.       ║"
  log "╚════════════════════════════════════════════════════════════════╝"

  # Create/update the warning file
  cat > "$STALE_WARNING_FILE" <<EOF
STALE FORECAST DATA WARNING
===========================
Variable: $VARIABLE
Generated: $(date -Iseconds)
Expected forecast date: $today
Actual forecast date: $forecast_date

The upstream data provider (gridMET/CFSv2) has not published today's forecast.
This pipeline is using the previous day's forecast data.
EOF

  log "Created stale data warning file: $STALE_WARNING_FILE"
}

# Clear stale warning if forecast is current
clear_stale_warning() {
  if [[ -f "$STALE_WARNING_FILE" ]]; then
    rm -f "$STALE_WARNING_FILE"
    log "Cleared previous stale data warning - forecast is now current"
  fi
}

# Track success state for S3 sync
SUCCESS=false

cleanup() {
  # Ensure temporary files are removed on script exit
  rm -f "$TEMP_FILENAME"
  rm -rf ./ensemble_temp_${VARIABLE}/

  # --- S3 Post-flight (only in cloud mode and only if successful) ---
  # SKIP_S3_SYNC: When set to "true", skip S3 sync (caller will handle it after all variables complete)
  # This prevents over-rotation when some variables are stale and cause retries
  if [ "${ENVIRONMENT:-local}" = "cloud" ] && [ "${SKIP_S3_SYNC:-false}" != "true" ]; then
    if [ "$SUCCESS" = true ]; then
      echo "--- Running in cloud mode: Syncing results to S3 for ${VARIABLE} ---"
      aws s3 sync --delete "$FORECAST_DATA_DIR" "${S3_BUCKET_PATH}/data/forecasts/${VARIABLE}/"
      aws s3 sync "$LOG_DIR" "${S3_BUCKET_PATH}/log/"
    else
      echo "--- Script failed: Skipping S3 sync to prevent uploading incomplete data ---" >&2
      # Still sync logs for debugging
      aws s3 sync "$LOG_DIR" "${S3_BUCKET_PATH}/log/" 2>/dev/null || true
    fi
  elif [ "${SKIP_S3_SYNC:-false}" = "true" ]; then
    echo "--- S3 sync deferred (SKIP_S3_SYNC=true) ---"
  fi
}

# Function to check if a variable uses ensemble files
uses_ensemble_format() {
  local var=$1
  # VPD has aggregated daily files
  # FM1000, FM100, tmax_2m, tmin_2m, etc. use ensemble format
  if [[ "$var" == "vpd" ]]; then
    return 1  # false - uses aggregated format
  else
    return 0  # true - uses ensemble format (default for most variables)
  fi
}

# Function to validate that the forecast file contains current data
# Returns 0 if forecast starts today or tomorrow, 1 if stale
# Outputs the forecast date to stdout for capture by caller
validate_forecast_date() {
  local nc_file=$1

  if ! command -v ncdump &> /dev/null; then
    log "WARNING: ncdump not found, skipping date validation"
    echo "unknown"
    return 0
  fi

  # Extract the first day value from the NetCDF file
  # The 'day' variable contains days since 1900-01-01
  # Note: ncdump outputs "day = N ;" for dimension size and " day = 45980, ..." for data values
  # We need the data line which contains 5-digit numbers (days since 1900 are ~45000+)
  local first_day
  first_day=$(ncdump -v day "$nc_file" 2>/dev/null | grep -oE "day = [0-9]{5}" | head -1 | grep -oE "[0-9]{5}")

  if [ -z "$first_day" ]; then
    log "WARNING: Could not extract date from $nc_file, skipping date validation"
    echo "unknown"
    return 0
  fi

  # Convert days since 1900-01-01 to date string
  local forecast_date
  forecast_date=$(date -d "1900-01-01 + ${first_day} days" +%Y-%m-%d 2>/dev/null)

  if [ -z "$forecast_date" ]; then
    log "WARNING: Could not convert day value $first_day to date, skipping validation"
    echo "unknown"
    return 0
  fi

  local today
  local tomorrow
  today=$(date +%Y-%m-%d)
  tomorrow=$(date -d "tomorrow" +%Y-%m-%d)

  log "Forecast file starts on: $forecast_date (today: $today, tomorrow: $tomorrow)"

  # Always output the forecast date for caller to capture
  echo "$forecast_date"

  if [[ "$forecast_date" == "$today" ]] || [[ "$forecast_date" == "$tomorrow" ]]; then
    log "✓ Forecast date is current"
    return 0
  else
    log "WARNING: Forecast is stale! File contains data starting $forecast_date but expected $today or $tomorrow"
    log "WARNING: The upstream data provider has not yet published today's forecast."
    return 1
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
  local EXPECTED_MEMBERS=16  # 4 hours × 4 members - all required

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

  # Require ALL ensemble members - no partial ensembles allowed
  if [ $download_count -ne $EXPECTED_MEMBERS ]; then
    log "ERROR: Incomplete ensemble for day $day: $download_count of $EXPECTED_MEMBERS members downloaded"
    log "ERROR: All ensemble members required for valid forecast. Aborting."
    rm -rf "$ensemble_dir"
    return 1
  fi

  log "Successfully downloaded all $EXPECTED_MEMBERS ensemble members for day $day"

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

  # If there's no existing forecast, download and create ensemble means for all 3 days
  if [[ ! -f "$TODAY_FILENAME" ]]; then
    log "No existing forecast files. Downloading ensemble members for days 0, 1, and 2..."

    # Download and create ensemble mean for day 0 (today)
    if download_ensemble_average 0 "$TODAY_FILENAME"; then
      log "Day 0 ensemble mean created successfully."
      # Validate that the downloaded data is current
      set +e
      FORECAST_DATE=$(validate_forecast_date "$TODAY_FILENAME")
      VALIDATE_STATUS=$?
      set -e
      if [ $VALIDATE_STATUS -ne 0 ]; then
        # No existing data to fall back on - check if we should accept stale data
        if handle_stale_data "$FORECAST_DATE"; then
          log "Accepting stale forecast data for initial download (no existing data to fall back on)."
          # Keep the file and continue
        else
          log "ERROR: Downloaded forecast data is stale (starts $FORECAST_DATE). Removing file."
          log "ERROR: Cannot proceed without any forecast data. Try again later."
          rm -f "$TODAY_FILENAME"
          exit 1
        fi
      else
        clear_stale_warning
      fi
    else
      log "ERROR: Day 0 ensemble download failed."
      exit 1
    fi

    # Download and create ensemble mean for day 1 (yesterday)
    if download_ensemble_average 1 "$Tminus1_FILENAME"; then
      log "Day 1 ensemble mean created successfully."
    else
      log "WARNING: Day 1 ensemble download failed. Continuing with day 0 only."
    fi

    # Download and create ensemble mean for day 2 (two days ago)
    if download_ensemble_average 2 "$Tminus2_FILENAME"; then
      log "Day 2 ensemble mean created successfully."
    else
      log "WARNING: Day 2 ensemble download failed. Continuing without day 2."
    fi

    log "Initial ensemble means created successfully."
    SUCCESS=true
    exit 0
  fi

  log "Starting forecast update check for ensemble data..."

  # Get the checksum of the current file to compare against
  OLD_CHECKSUM=$(sha256sum "$TODAY_FILENAME" | awk '{print $1}')

  log "Downloading new ensemble members to check for updates..."

  # Download and create new ensemble mean
  if ! download_ensemble_average 0 "$TEMP_FILENAME"; then
    log "WARNING: Failed to download new ensemble data."
    if handle_stale_data "download_failed"; then
      log "Proceeding with existing forecast data."
      SUCCESS=true
      exit 0
    else
      log "ERROR: Will retry to get fresh data."
      exit 1
    fi
  fi

  # Validate that the downloaded data is current before proceeding
  # Capture the forecast date for potential warning message
  set +e
  FORECAST_DATE=$(validate_forecast_date "$TEMP_FILENAME")
  VALIDATE_STATUS=$?
  set -e

  if [ $VALIDATE_STATUS -ne 0 ]; then
    log "Downloaded forecast data is stale (starts $FORECAST_DATE)."
    rm -f "$TEMP_FILENAME"
    if handle_stale_data "$FORECAST_DATE"; then
      log "Proceeding with existing forecast data."
      SUCCESS=true
      exit 0
    else
      log "ERROR: Will retry to get fresh data."
      exit 1
    fi
  fi

  # Fresh data available - clear any previous stale warning
  clear_stale_warning

  # Get the checksum of the new file
  NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

  # Compare checksums
  if [[ "$OLD_CHECKSUM" == "$NEW_CHECKSUM" ]]; then
    log "No update detected. Forecast is unchanged but current."
    rm -f "$TEMP_FILENAME"
    SUCCESS=true
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
  SUCCESS=true
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
      # Validate that the downloaded data is current
      set +e
      FORECAST_DATE=$(validate_forecast_date "$TODAY_FILENAME")
      VALIDATE_STATUS=$?
      set -e
      if [ $VALIDATE_STATUS -ne 0 ]; then
        # No existing data to fall back on - check if we should accept stale data
        if handle_stale_data "$FORECAST_DATE"; then
          log "Accepting stale forecast data for initial download (no existing data to fall back on)."
          # Keep the file and continue
        else
          log "ERROR: Downloaded forecast data is stale (starts $FORECAST_DATE). Removing file."
          log "ERROR: Cannot proceed without any forecast data. Try again later."
          rm -f "$TODAY_FILENAME"
          exit 1
        fi
      else
        clear_stale_warning
      fi
      SUCCESS=true
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
    log "WARNING: Download failed."
    if handle_stale_data "download_failed"; then
      log "Proceeding with existing forecast data."
      SUCCESS=true
      exit 0
    else
      log "ERROR: Will retry to get fresh data."
      exit 1
    fi
  fi

  # Validate that the downloaded data is current before proceeding
  # Capture the forecast date for potential warning message
  set +e
  FORECAST_DATE=$(validate_forecast_date "$TEMP_FILENAME")
  VALIDATE_STATUS=$?
  set -e

  if [ $VALIDATE_STATUS -ne 0 ]; then
    log "Downloaded forecast data is stale (starts $FORECAST_DATE)."
    rm -f "$TEMP_FILENAME"
    if handle_stale_data "$FORECAST_DATE"; then
      log "Proceeding with existing forecast data."
      SUCCESS=true
      exit 0
    else
      log "ERROR: Will retry to get fresh data."
      exit 1
    fi
  fi

  # Fresh data available - clear any previous stale warning
  clear_stale_warning

  # Get the checksum of the new file
  NEW_CHECKSUM=$(sha256sum "$TEMP_FILENAME" | awk '{print $1}')

  # Compare checksums
  if [[ "$OLD_CHECKSUM" == "$NEW_CHECKSUM" ]]; then
    log "No update detected. Forecast is unchanged but current."
    rm -f "$TEMP_FILENAME"
    SUCCESS=true
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
  SUCCESS=true
  exit 0
fi
