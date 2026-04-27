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

## Climate-data end (gridMET / NPSWB calendar bound — 1979-01-01 through this date)
RETROSPECTIVE_END_DATE <- as.Date("2024-12-31")

## MTBS perimeter end — the most recent fire ignition date in
## mtbs_polys_plus_cover_ecoregion.gpkg (the post-cover-join file the
## analysis actually reads). Not an arbitrary cutoff; it is the natural
## endpoint of the gpkg derived from the 2025-08-22 MTBS release.
##
## Note: this is *earlier* than the raw mtbs_perims_DD.shp max
## (2024-12-17), because extract_cover.R filters events that fail the
## cover/ecoregion join. The analysis pipeline reads the gpkg, so this
## constant tracks the gpkg's max(Ig_Date) — not the raw shapefile's.
##
## When MTBS publishes a new release, re-running extract_cover.R will
## produce a gpkg with a different max(Ig_Date) — update this constant
## to match and treat the resulting analysis as a new vintage.
RETROSPECTIVE_MTBS_END_DATE <- as.Date("2024-12-08")
