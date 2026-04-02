#!/bin/bash

## Download MACA v2 Metdata climate projections for Sierra Nevada ecoregion
## Variables: VPD, tasmax (tmmx), tasmin (tmmn)
## Source: http://thredds.northwestknowledge.net:8080/thredds/reacch_climate_CMIP5_aggregated_macav2_catalog.html
## Spatial subset to Sierra Nevada bounding box
## Output follows same naming convention as GYE downloads in /media/steve/THREDDS/data/MACA/gye/

trap 'rm -f "$TMPFILE"' EXIT

var="vpd tmmx tmmn"
pathways="rcp45 rcp85"
gcms="BNU-ESM CNRM-CM5 CSIRO-Mk3-6-0 bcc-csm1-1 CanESM2 GFDL-ESM2G GFDL-ESM2M HadGEM2-CC365 HadGEM2-ES365 inmcm4 MIROC5 MIROC-ESM MIROC-ESM-CHEM MRI-CGCM3 IPSL-CM5A-LR IPSL-CM5A-MR IPSL-CM5B-LR CCSM4 NorESM1-M bcc-csm1-1-m"

timestep="daily"

## Sierra Nevada bounding box (from EPA L3 ecoregion shapefile)
north=40.42355
west=-121.63545
east=-117.87015
south=34.81587

out_dir="/media/steve/THREDDS/data/MACA/sien/forecasts/${timestep}"
mkdir -p "$out_dir"

for model in $gcms; do
    for scenario in $pathways; do
        for par in $var; do
            echo "$par $model $scenario"
            OUT_FILE="${out_dir}/${par}_${model}_${scenario}_2006-2099_${timestep}_sien.nc"
            if [ -f "$OUT_FILE" ]; then
                echo "  Already exists, skipping."
                continue
            fi
            TMPFILE=$(mktemp) || exit 1
            case $par in
                "vpd")
                    wget -O "$TMPFILE" "http://thredds.northwestknowledge.net:8080/thredds/ncss/agg_macav2metdata_vpd_${model}_r1i1p1_${scenario}_2006_2099_CONUS_${timestep}.nc?var=vpd&north=${north}&west=${west}&east=${east}&south=${south}&disableProjSubset=on&horizStride=1&time_start=2006-01-01T00%3A00%3A00Z&time_end=2099-12-31T00%3A00%3A00Z&timeStride=1&accept=netcdf"
                    ;;
                "tmmx")
                    wget -O "$TMPFILE" "http://thredds.northwestknowledge.net:8080/thredds/ncss/agg_macav2metdata_tasmax_${model}_r1i1p1_${scenario}_2006_2099_CONUS_${timestep}.nc?var=air_temperature&north=${north}&west=${west}&east=${east}&south=${south}&disableProjSubset=on&horizStride=1&time_start=2006-01-01T00%3A00%3A00Z&time_end=2099-12-31T00%3A00%3A00Z&timeStride=1&accept=netcdf"
                    ;;
                "tmmn")
                    wget -O "$TMPFILE" "http://thredds.northwestknowledge.net:8080/thredds/ncss/agg_macav2metdata_tasmin_${model}_r1i1p1_${scenario}_2006_2099_CONUS_${timestep}.nc?var=air_temperature&north=${north}&west=${west}&east=${east}&south=${south}&disableProjSubset=on&horizStride=1&time_start=2006-01-01T00%3A00%3A00Z&time_end=2099-12-31T00%3A00%3A00Z&timeStride=1&accept=netcdf"
                    ;;
            esac
            if [ $? -eq 0 ] && [ -s "$TMPFILE" ]; then
                nccopy -d1 -s "$TMPFILE" "$OUT_FILE"
                echo "  Saved: $OUT_FILE"
            else
                echo "  ERROR: Download failed for $par $model $scenario"
            fi
            rm -f "$TMPFILE"
        done
    done
done
