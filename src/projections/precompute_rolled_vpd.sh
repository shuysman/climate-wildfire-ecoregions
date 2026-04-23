#!/bin/bash

## Precompute rolled VPD from MACA vpd using CDO
##
## For each GCM/scenario, produces:
##   1. vpd_rolled_3_*_sien.nc  — 3-day rolling mean VPD (forest predictor)
##   2. vpd_rolled_17_*_sien.nc — 17-day rolling mean VPD (non-forest predictor)
##
## CDO handles rolling-window operations in seconds vs minutes in R. The
## ecoregion mask is applied downstream in R via the classified cover raster,
## so we keep the full MACA grid here.
##
## Usage: bash precompute_rolled_vpd.sh
## Prerequisites: MACA vpd downloads available in $data_dir

data_dir="/media/steve/THREDDS/data/MACA/sien/forecasts/daily"

echo "========================================="
echo "Precomputing rolled VPD (3-day, 17-day)"
echo "========================================="

for vpd_file in "${data_dir}"/vpd_*_sien.nc; do
    [ -f "$vpd_file" ] || continue

    basename=$(basename "$vpd_file")
    ## Skip already-rolled outputs
    case "$basename" in
        vpd_rolled_*) continue ;;
    esac

    suffix="${basename#vpd_}"  # e.g. BNU-ESM_rcp45_2006-2099_daily_sien.nc

    vpd_rolled_3_file="${data_dir}/vpd_rolled_3_${suffix}"
    vpd_rolled_17_file="${data_dir}/vpd_rolled_17_${suffix}"

    ## --- VPD: 3-day rolling mean (forest) ---
    if [ -f "$vpd_rolled_3_file" ]; then
        echo "Already exists: $(basename $vpd_rolled_3_file)"
    else
        echo "Computing VPD rolled 3-day mean: $(basename $vpd_rolled_3_file)"
        cdo -s --timestat_date last -z zip_4 -runmean,3 "$vpd_file" "$vpd_rolled_3_file"
        echo "  Done: $(ls -lh "$vpd_rolled_3_file" | awk '{print $5}')"
    fi

    ## --- VPD: 17-day rolling mean (non-forest) ---
    if [ -f "$vpd_rolled_17_file" ]; then
        echo "Already exists: $(basename $vpd_rolled_17_file)"
    else
        echo "Computing VPD rolled 17-day mean: $(basename $vpd_rolled_17_file)"
        cdo -s --timestat_date last -z zip_4 -runmean,17 "$vpd_file" "$vpd_rolled_17_file"
        echo "  Done: $(ls -lh "$vpd_rolled_17_file" | awk '{print $5}')"
    fi
done

echo "========================================="
echo "Precomputation complete."
echo "========================================="
