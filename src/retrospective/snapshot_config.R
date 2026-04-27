## Pinned dates for the current retrospective analysis snapshot.
##
## All retrospective scripts (extract_*.R, dryness_roc_analysis.R,
## generate_ecdf_*.R, save_quantiles_*.R) source this file so the eCDF
## training data and the quantile raster climatology share the same
## historical end date.
##
## Why this matters: gridMET ships new daily files indefinitely. Without a
## pinned cutoff, re-running save_quantiles_*.R against a freshly-downloaded
## gridMET tree would compute percentiles over a different time window than
## the eCDFs were trained on, silently breaking the percentile→fire-danger
## lookup at forecast time.
##
## When regenerating the snapshot (running extract_gridmet.R / extract_npswb.R
## / extract_cover.R against newer upstream releases), update this date to
## match the new parquet/MTBS coverage and treat the resulting eCDF +
## quantile + cover-counts artifacts as a new analysis vintage rather than
## an in-place update.

RETROSPECTIVE_END_DATE <- as.Date("2024-12-31")
