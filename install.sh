#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --- Check for R ---

echo "Checking for R installation..."
if ! command -v R &> /dev/null
then
    echo "R could not be found. Please install R for your operating system."
    echo "Installation instructions can be found at: https://cloud.r-project.org/"
    exit 1
fi
echo "R is installed."

# --- Check for renv ---

echo "Checking for renv package..."
if ! Rscript -e "if (!requireNamespace('renv', quietly = TRUE)) { quit(status = 1) }" &> /dev/null
then
    echo "renv package not found. Installing renv..."
    Rscript -e "install.packages('renv', repos = 'https://cloud.r-project.org/')"
fi
echo "renv package is installed."

# Get the absolute path to the project directory
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# --- 1. Set up R environment ---
echo "Setting up R environment with renv..."
Rscript -e "renv::restore()"

# --- 2. Make scripts executable ---
echo "Making forecast scripts executable..."
chmod +x "$PROJECT_DIR/src/daily_forecast.sh"
chmod +x "$PROJECT_DIR/src/hourly_lightning_map.sh"
chmod +x "$PROJECT_DIR/src/generate_daily_html.sh"
chmod +x "$PROJECT_DIR/src/update_rotate_vpd_forecasts.sh"

# --- 3. Set up cron jobs ---
echo "Setting up cron jobs..."

# Cron job for the daily forecast (runs at 10:00 AM every day)
DAILY_CRON_JOB="0 10 * * * $PROJECT_DIR/src/daily_forecast.sh"

# Cron job for the hourly lightning map (runs at the beginning of every hour)
HOURLY_CRON_JOB="0 * * * * $PROJECT_DIR/src/hourly_lightning_map.sh"

# Add cron jobs to the user's crontab
(crontab -l 2>/dev/null; echo "$DAILY_CRON_JOB"; echo "$HOURLY_CRON_JOB") | crontab -

echo "
--- Installation Complete! ---

The following cron jobs have been added to your crontab:
- Daily forecast at 10:00 AM
- Hourly lightning map at the beginning of every hour

You can edit these by running 'crontab -e'.
"
