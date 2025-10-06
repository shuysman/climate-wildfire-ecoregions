#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "Starting hourly lightning map generation..."

# Run the lightning map generation script
Rscript /home/steve/sync/pyrome-fire/src/map_lightning.R

echo "Hourly lightning map generation complete."
