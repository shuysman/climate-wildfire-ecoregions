#!/bin/bash

## Compute period-mean per-GCM and across-GCM ensemble statistics from
## per-cover 4km day-count NetCDFs produced by compute_thresholds.R.
##
## Two stages:
##
## (A) Per-GCM period mean (cdo ensmean across the period's annual files —
##     each year file is treated as one ensemble member of the time-axis).
##
## (B) Across-GCM ensemble stats (cdo ensmean / ensmedian / enspctl,25 /
##     enspctl,75) on the per-GCM period-mean files.
##
## Both stages are CDO and stream through input files; peak RAM is well
## under 1 GB regardless of N GCMs or N years in the period. Outputs land
## in <out_root>/<scenario>/4km/<period>_ens_<stat>_<cover>.nc.
##
## Then 30m resample + cover-combine is delegated to ensemble_to_30m.R.
##
## Usage: bash compute_period_ensemble.sh <scenario> <period_name>
## Example: bash compute_period_ensemble.sh rcp45 mid_century

set -u

scenario=$1
period_name=$2

case "$period_name" in
    near_term)   year_start=2021; year_end=2040 ;;
    mid_century) year_start=2041; year_end=2060 ;;
    end_century) year_start=2070; year_end=2099 ;;
    *) echo "Unknown period: $period_name (expected near_term|mid_century|end_century)"; exit 1 ;;
esac

## CDO -P N enables OpenMP threading inside each operator. Default leaves a
## couple of cores for the system; override via env var if running alongside
## other heavy work, e.g. CDO_THREADS=8 bash compute_period_ensemble.sh ...
NCPU=$(nproc)
CDO_THREADS=${CDO_THREADS:-$(( NCPU > 4 ? NCPU - 2 : NCPU ))}
echo "CDO threads: $CDO_THREADS  (host nproc=$NCPU)"

THREDDS_ROOT="${THREDDS_ROOT:-/media/steve/THREDDS}"
proj_dir="${THREDDS_ROOT}/data/MACA/sien/projections"
out_root="${THREDDS_ROOT}/data/MACA/sien/ensemble_thresholds"
out_dir="$out_root/$scenario/4km"
mkdir -p "$out_dir"

## Discover GCM dirs containing the requested scenario subdir.
gcms=()
for d in "$proj_dir"/*/; do
    g=$(basename "$d")
    [[ "$g" == _* ]] && continue
    [ -d "$d$scenario" ] && gcms+=("$g")
done

echo "========================================="
echo "Period ensemble: $scenario $period_name ($year_start-$year_end)"
echo "N GCMs: ${#gcms[@]}"
echo "========================================="

start=$(date +%s)
scratch=$(mktemp -d)
trap "rm -rf $scratch" EXIT

for cover in forest non_forest; do
    echo "--- $cover ---"

    ## Stage A: per-GCM period mean
    per_gcm_files=()
    for g in "${gcms[@]}"; do
        year_files=()
        for yr in $(seq $year_start $year_end); do
            f="$proj_dir/$g/$scenario/${yr}_days_above_thresholds_${cover}.nc"
            [ -f "$f" ] && year_files+=("$f")
        done
        if [ ${#year_files[@]} -eq 0 ]; then
            echo "  WARN: $g has no year files for $period_name $cover, skipping"
            continue
        fi
        out="$scratch/${g}_${cover}.nc"
        cdo -s -P "$CDO_THREADS" ensmean "${year_files[@]}" "$out"
        per_gcm_files+=("$out")
    done
    echo "  per-GCM period means computed: ${#per_gcm_files[@]}/${#gcms[@]}"

    if [ ${#per_gcm_files[@]} -eq 0 ]; then
        echo "  ERROR: no per-GCM files for $cover, aborting cover"
        continue
    fi

    ## Stage B: across-GCM stats
    for stat in mean median q25 q75; do
        case $stat in
            mean)   op=ensmean ;;
            median) op=ensmedian ;;
            q25)    op=enspctl,25 ;;
            q75)    op=enspctl,75 ;;
        esac
        out_file="$out_dir/${period_name}_ens_${stat}_${cover}.nc"
        cdo -s -O -P "$CDO_THREADS" $op "${per_gcm_files[@]}" "$out_file"
        sz=$(du -k "$out_file" | cut -f1)
        echo "  wrote $(basename $out_file) (${sz} kB)"
    done
done

elapsed=$(( $(date +%s) - start ))
echo "========================================="
echo "4km ensemble stats complete in ${elapsed}s"
echo "Output dir: $out_dir"
echo "========================================="

## Stage C: 30m resample + cover combine via R
echo "[$(date '+%H:%M:%S')] launching ensemble_to_30m.R for $scenario $period_name"
cd /home/steve/sync/pyrome-fire
Rscript src/projections/ensemble_to_30m.R "$scenario" "$period_name"
