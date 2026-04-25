#!/bin/bash

## Top-level driver: compute period-ensemble products for all
## (scenario × period) combinations sequentially.
##
## Periods follow IPCC AR5/AR6 convention adapted to the MACA RCP futures
## (which start in 2006 here) and the western-US fire literature standard
## of 2070-2099 for end-of-century:
##
##   near_term   = 2021-2040
##   mid_century = 2041-2060
##   end_century = 2070-2099
##
## Each (scenario, period) call:
##   1. cdo per-GCM period mean → cdo across-GCM stats (mean/median/q25/q75)
##      at 4km (compute_period_ensemble.sh, low-RAM CDO streaming)
##   2. R 30m resample + cover-combine (ensemble_to_30m.R)
##
## Sequential by default — peak RSS for each (scenario, period) is ~5-8 GB
## from the R 30m step. To run scenarios in parallel, kick off two
## invocations of this script (one per scenario) — they don't share files.
##
## Usage: bash run_ensembles.sh [scenario]
##   scenario optional — defaults to running both rcp45 and rcp85
##
## Resume-safe: ensemble_to_30m.R skips any (period, stat) whose final 30m
## TIF already exists; CDO outputs are overwritten unconditionally.

set -u

scenarios="${1:-rcp45 rcp85}"
periods="near_term mid_century end_century"

start=$(date +%s)
echo "========================================="
echo "Period-ensemble run"
echo "Scenarios: $scenarios"
echo "Periods:   $periods"
echo "========================================="

for scenario in $scenarios; do
    for period_name in $periods; do
        echo ""
        echo "----- $scenario $period_name -----"
        bash src/projections/compute_period_ensemble.sh "$scenario" "$period_name"
    done
done

elapsed=$(( $(date +%s) - start ))
echo "========================================="
echo "All ensemble products complete in ${elapsed}s"
echo "========================================="
