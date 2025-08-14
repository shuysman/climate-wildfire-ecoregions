#!/bin/bash
###############################################################################
#       Retrieve gridMET NetCDF files for 1979 to 2024 for all of CONUS       #
###############################################################################

YEARS=$(seq 1979 2024)
OUT_DIR="${HOME}/data/gridmet"

wget -P "$OUT_DIR" -nc -c -nd  https://www.northwestknowledge.net/metdata/data/pdsi.nc

for YEAR in $YEARS; do
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/vpd_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/pr_${YEAR}.nc"
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/rmin_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/rmax_${YEAR}.nc"
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/tmmn_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/tmmx_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/erc_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/bi_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/fm100_${YEAR}.nc" 
    wget -P "$OUT_DIR" -nc -c -nd "http://www.northwestknowledge.net/metdata/data/fm1000_${YEAR}.nc" 
done
