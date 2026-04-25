## Ensemble-summarize per-GCM days-above-threshold and write 30m products.
##
## Reads the per-cover 4km day-count NetCDFs produced by compute_thresholds.R
## across all available GCMs for one scenario, computes ensemble statistics
## (median, mean, q25, q75) per threshold per cover at 4km, then resamples to
## 30m and combines via classified cover — the 30m work happens once per
## ensemble product instead of once per (GCM × scenario × year).
##
## Per-GCM inputs:
##   <projections_dir>/<MODEL>/<SCENARIO>/<YEAR>_days_above_thresholds_forest.nc
##   <projections_dir>/<MODEL>/<SCENARIO>/<YEAR>_days_above_thresholds_non_forest.nc
##   (4 bands each, one per threshold in 0.50/0.75/0.90/0.95)
##
## Outputs (30m GeoTIFF, 4 bands per file — one per threshold):
##   <out_base_dir>/<SCENARIO>/<YEAR>_ensemble_median_days_above_thresholds.tif
##   <out_base_dir>/<SCENARIO>/<YEAR>_ensemble_mean_days_above_thresholds.tif
##   <out_base_dir>/<SCENARIO>/<YEAR>_ensemble_q25_days_above_thresholds.tif
##   <out_base_dir>/<SCENARIO>/<YEAR>_ensemble_q75_days_above_thresholds.tif
##
## Skip logic: a year is skipped when all 4 stat outputs already exist.
##
## Usage: Rscript ensemble_thresholds.R <scenario> [start_year] [end_year]
## Example: Rscript ensemble_thresholds.R rcp45
##          Rscript ensemble_thresholds.R rcp85 2050 2099

library(terra)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("Usage: Rscript ensemble_thresholds.R <scenario> [start_year] [end_year]")
}
scenario <- args[1]
start_year <- if (length(args) >= 2) as.integer(args[2]) else NULL
end_year <- if (length(args) >= 3) as.integer(args[3]) else NULL

message(glue("========================================"))
message(glue("Ensemble Days-Above-Threshold Summary"))
message(glue("Scenario: {scenario}"))
message(glue("========================================"))

start_time <- Sys.time()
terraOptions(verbose = FALSE, memfrac = 0.6)

## ============================================================================
## CONFIGURATION
## ============================================================================

ecoregion_id    <- 5
projections_dir <- "/media/steve/THREDDS/data/MACA/sien/projections"
out_base_dir    <- "/media/steve/THREDDS/data/MACA/sien/ensemble_thresholds"
thresholds      <- c(0.50, 0.75, 0.90, 0.95)
threshold_names <- paste0("days_above_", as.integer(round(thresholds * 100)))  # matches compute_thresholds.R
stats           <- c("median", "mean", "q25", "q75")

stat_funcs <- list(
  median = function(x) median(x, na.rm = TRUE),
  mean   = function(x) mean(x,   na.rm = TRUE),
  q25    = function(x) stats::quantile(x, 0.25, na.rm = TRUE, names = FALSE),
  q75    = function(x) stats::quantile(x, 0.75, na.rm = TRUE, names = FALSE)
)

## ============================================================================
## DISCOVER GCMs FOR THIS SCENARIO
## ============================================================================

gcm_dirs <- list.dirs(projections_dir, recursive = FALSE)
gcms <- basename(gcm_dirs[file.exists(file.path(gcm_dirs, scenario))])
gcms <- gcms[!startsWith(gcms, "_")]  # skip _ensemble or other meta dirs
message(glue("Found {length(gcms)} GCM dirs for scenario {scenario}: {paste(gcms, collapse=', ')}"))

## ============================================================================
## LOAD CLASSIFIED COVER, PROJECT TO MACA GRID
## ============================================================================

message("Loading classified cover raster...")
classified_rast <- rast(glue("data/classified_cover/ecoregion_{ecoregion_id}_classified.tif"))

## Use any per-GCM fire-danger NC as the CRS template (MACA 0-360).
sample_path <- NULL
for (g in gcms) {
  cand <- list.files(file.path(projections_dir, g, scenario),
                     pattern = "_fire_danger_forest\\.nc$", full.names = TRUE)
  if (length(cand) > 0) { sample_path <- cand[1]; break }
}
if (is.null(sample_path)) stop("No per-GCM fire-danger files found — cannot establish CRS template.")
classified_rast <- project(classified_rast, crs(rast(sample_path)))
forest_mask <- classified_rast == "forest"

out_dir <- file.path(out_base_dir, scenario)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## ============================================================================
## YEAR LOOP
## ============================================================================

available_years <- 2006:2099
if (!is.null(start_year)) available_years <- available_years[available_years >= start_year]
if (!is.null(end_year))   available_years <- available_years[available_years <= end_year]

for (yr in available_years) {
  yr_start <- Sys.time()

  out_paths <- setNames(
    file.path(out_dir, glue("{yr}_ensemble_{stats}_days_above_thresholds.tif")),
    stats
  )
  if (all(file.exists(out_paths))) {
    message(glue("  {yr}: all stat outputs exist, skipping."))
    next
  }

  ## Build per-GCM input paths and filter to GCMs that have BOTH cover files
  forest_paths <- file.path(projections_dir, gcms, scenario,
                            glue("{yr}_days_above_thresholds_forest.nc"))
  nonforest_paths <- file.path(projections_dir, gcms, scenario,
                               glue("{yr}_days_above_thresholds_non_forest.nc"))
  has_both <- file.exists(forest_paths) & file.exists(nonforest_paths)
  forest_paths <- forest_paths[has_both]
  nonforest_paths <- nonforest_paths[has_both]
  n_gcms <- length(forest_paths)

  if (n_gcms == 0) {
    message(glue("  {yr}: no GCMs have data, skipping."))
    next
  }

  message(glue("--- Year {yr} (n_gcms={n_gcms}) ---"))

  ## For each cover type, compute ensemble stats per threshold at 4km.
  ## per_thresh_stacks is a list of length(thresholds) of N-layer 4km rasters
  ## (one layer per GCM). Each app() call collapses across the GCM dim,
  ## producing a single 4km layer per (cover, threshold, stat). Inputs are
  ## NetCDFs with one CF variable per threshold (named e.g. days_above_50);
  ## index by variable name rather than integer position to be robust to
  ## threshold reordering.
  compute_per_cover_stats <- function(paths) {
    per_thresh_stacks <- lapply(threshold_names, function(vname) {
      rast(lapply(paths, function(p) rast(p, subds = vname)))
    })
    out <- list()
    for (s in stats) {
      out[[s]] <- rast(lapply(per_thresh_stacks, function(stk) app(stk, fun = stat_funcs[[s]])))
      names(out[[s]]) <- paste0(s, "_", threshold_names)
    }
    out
  }

  forest_stats    <- compute_per_cover_stats(forest_paths)
  nonforest_stats <- compute_per_cover_stats(nonforest_paths)

  ## For each stat: single multi-band resample per cover, then per-threshold
  ## lapp to combine via cover. Process one stat at a time so each stat's
  ## 30m intermediates are GC'd before the next iteration.
  for (s in stats) {
    if (file.exists(out_paths[[s]])) next

    forest_30m    <- resample(forest_stats[[s]],    classified_rast, method = "near")
    nonforest_30m <- resample(nonforest_stats[[s]], classified_rast, method = "near")

    layers <- vector("list", length(thresholds))
    for (i in seq_along(thresholds)) {
      layers[[i]] <- lapp(c(forest_30m[[i]], nonforest_30m[[i]], forest_mask),
                          fun = function(f, n, m) ifelse(m == 1, f, n))
    }
    out_rast <- rast(layers)
    names(out_rast) <- paste0(s, "_", threshold_names)

    ## FLT4S because mean / q25 / q75 produce non-integer values (median can
    ## also be x.5 for even N). ZLEVEL=2 + tiling compresses NA-heavy 30m
    ## floats efficiently.
    writeRaster(out_rast, out_paths[[s]], overwrite = TRUE, datatype = "FLT4S",
                gdal = c("COMPRESS=DEFLATE", "ZLEVEL=2", "TILED=YES",
                         "BLOCKXSIZE=512", "BLOCKYSIZE=512", "BIGTIFF=IF_SAFER"))

    rm(forest_30m, nonforest_30m, layers, out_rast)
  }

  rm(forest_stats, nonforest_stats)
  gc()

  yr_elapsed <- round(as.numeric(difftime(Sys.time(), yr_start, units = "secs")), 1)
  message(glue("  Year {yr} complete in {yr_elapsed} s (n_gcms={n_gcms})"))
}

elapsed <- round(difftime(Sys.time(), start_time, units = "mins"), 1)
message(glue("========================================"))
message(glue("Ensemble computation complete: {scenario}"))
message(glue("Elapsed time: {elapsed} min"))
message(glue("Output: {out_dir}"))
message(glue("========================================"))
