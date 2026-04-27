## Compute days-above-threshold summaries from daily fire danger projections
##
## Per-GCM/scenario step: writes one 4km NetCDF per cover type per year, each
## with a band per threshold. The 30m resample + cover-mask combine is
## intentionally deferred to the ensemble step (`ensemble_thresholds.R`),
## where it runs once per ensemble product instead of once per
## (GCM × scenario × year). This keeps per-year cost ~tens of seconds and
## peak RSS ~3-5 GB, so the full sweep parallelizes safely across GCMs.
##
## Usage: Rscript compute_thresholds.R <model> <scenario> [start_year] [end_year]
## Example: Rscript compute_thresholds.R BNU-ESM rcp45
##          Rscript compute_thresholds.R BNU-ESM rcp45 2050 2099

library(terra)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript compute_thresholds.R <model> <scenario> [start_year] [end_year]")
}

model <- args[1]
scenario <- args[2]
start_year <- if (length(args) >= 3) as.integer(args[3]) else NULL
end_year <- if (length(args) >= 4) as.integer(args[4]) else NULL

message(glue("========================================"))
message(glue("Days-Above-Threshold Computation"))
message(glue("Model: {model}  Scenario: {scenario}"))
message(glue("========================================"))

start_time <- Sys.time()

terraOptions(verbose = FALSE, memfrac = 0.6)

## ============================================================================
## CONFIGURATION
## ============================================================================

thredds_root <- Sys.getenv("THREDDS_ROOT", "/media/steve/THREDDS")
projections_dir <- file.path(thredds_root, "data/MACA/sien/projections", model, scenario)
thresholds <- c(0.50, 0.75, 0.90, 0.95)

## ============================================================================
## FIND YEARS TO PROCESS
## ============================================================================

forest_files <- sort(list.files(projections_dir, pattern = "_fire_danger_forest\\.nc$"))
available_years <- as.integer(gsub("_fire_danger_forest\\.nc$", "", forest_files))

if (!is.null(start_year)) available_years <- available_years[available_years >= start_year]
if (!is.null(end_year)) available_years <- available_years[available_years <= end_year]

message(glue("Years to process: {min(available_years)}-{max(available_years)} ({length(available_years)} years)"))

## ============================================================================
## PROCESS EACH YEAR — write one 4km NetCDF per cover type
## ============================================================================

## Return a SpatRasterDataset with one variable per threshold so the band
## labels round-trip through NetCDF. writeCDF on a multi-band SpatRaster
## collapses bands into an auto-named Z dim (e.g. days_above_thresholds_Z1=1)
## and loses our threshold labels. SDS writes each variable separately,
## preserving the names. Variable names use whole-percent (50/75/90/95) to
## avoid dots in CF variable names.
count_days_above <- function(daily_rast, thresholds) {
  layers <- lapply(thresholds, function(t) {
    app(daily_rast > t, fun = sum, na.rm = TRUE)
  })
  out <- sds(layers)
  names(out) <- paste0("days_above_", as.integer(round(thresholds * 100)))
  out
}

for (yr in available_years) {
  yr_start <- Sys.time()

  forest_in <- file.path(projections_dir, glue("{yr}_fire_danger_forest.nc"))
  non_forest_in <- file.path(projections_dir, glue("{yr}_fire_danger_non_forest.nc"))
  forest_out <- file.path(projections_dir, glue("{yr}_days_above_thresholds_forest.nc"))
  non_forest_out <- file.path(projections_dir, glue("{yr}_days_above_thresholds_non_forest.nc"))

  if (file.exists(forest_out) && file.exists(non_forest_out)) {
    message(glue("  {yr}: already exists, skipping."))
    next
  }

  if (!file.exists(forest_in) || !file.exists(non_forest_in)) {
    message(glue("  {yr}: missing fire danger files, skipping."))
    next
  }

  message(glue("--- Year {yr} ---"))

  forest_daily <- rast(forest_in)
  non_forest_daily <- rast(non_forest_in)

  forest_counts <- count_days_above(forest_daily, thresholds)
  nonforest_counts <- count_days_above(non_forest_daily, thresholds)

  ## writeCDF on an sds writes one CF variable per element of the sds,
  ## using its names. No `varname=` here — that arg is for SpatRaster, not sds.
  writeCDF(forest_counts, forest_out, overwrite = TRUE, compression = 4)
  writeCDF(nonforest_counts, non_forest_out, overwrite = TRUE, compression = 4)

  rm(forest_daily, non_forest_daily, forest_counts, nonforest_counts)
  gc()

  yr_elapsed <- round(as.numeric(difftime(Sys.time(), yr_start, units = "secs")), 1)
  fsize_kb <- round((file.size(forest_out) + file.size(non_forest_out)) / 1024, 1)
  message(glue("  Year {yr} complete in {yr_elapsed} s ({fsize_kb} kB total)"))
}

elapsed <- round(difftime(Sys.time(), start_time, units = "mins"), 1)
message(glue("========================================"))
message(glue("Threshold computation complete: {model} {scenario}"))
message(glue("Elapsed time: {elapsed} min"))
message(glue("========================================"))
