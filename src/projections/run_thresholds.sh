#!/bin/bash

## Compute days-above-threshold summaries for all GCM/scenario combinations
## Usage: bash run_thresholds.sh [--parallel N]
##
## By default runs sequentially. Use --parallel N to run N jobs at a time.
## Reads <YEAR>_fire_danger_{forest,non_forest}.nc and writes
## <YEAR>_days_above_thresholds.tif (30m GeoTIFF) per year.
##
## Skip logic in compute_thresholds.R picks up where it left off, so this is
## safe to run while project_fire_danger.R is still producing fire danger
## files for other GCMs — partial GCMs will threshold the years that exist
## and skip the rest.

PARALLEL=1

if [ "$1" == "--parallel" ] && [ -n "$2" ]; then
    PARALLEL=$2
fi

THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}"
log_dir="${THREDDS_ROOT}/data/MACA/sien/projections"

gcms="BNU-ESM CNRM-CM5 CSIRO-Mk3-6-0 bcc-csm1-1 CanESM2 GFDL-ESM2G GFDL-ESM2M HadGEM2-CC365 HadGEM2-ES365 inmcm4 MIROC5 MIROC-ESM MIROC-ESM-CHEM MRI-CGCM3 IPSL-CM5A-LR IPSL-CM5A-MR IPSL-CM5B-LR CCSM4 NorESM1-M bcc-csm1-1-m"
scenarios="rcp45 rcp85"

total=0
for model in $gcms; do
    for scenario in $scenarios; do
        total=$((total + 1))
    done
done

echo "========================================="
echo "Sierra Nevada Days-Above-Threshold Summaries"
echo "Total jobs: $total (parallelism: $PARALLEL)"
echo "========================================="

count=0
running=0

for model in $gcms; do
    for scenario in $scenarios; do
        count=$((count + 1))
        echo "[$count/$total] Starting: $model $scenario"

        Rscript src/projections/compute_thresholds.R "$model" "$scenario" \
            > "${log_dir}/${model}_${scenario}_thresholds.log" 2>&1 &

        running=$((running + 1))

        if [ "$running" -ge "$PARALLEL" ]; then
            wait -n
            running=$((running - 1))
        fi
    done
done

wait
echo "========================================="
echo "All threshold summaries complete."
echo "========================================="
