#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "Starting hourly lightning map generation..."

# Run the lightning map generation script
Rscript ./src/map_lightning.R

echo "Hourly lightning map generation complete."
