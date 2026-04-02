## Compute days-above-threshold summaries from daily fire danger projections
##
## Post-processing step: combines separate forest/non-forest daily fire danger
## rasters via 30m classified cover to produce annual threshold summaries.
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

terraOptions(verbose = FALSE, memfrac = 0.9)

## ============================================================================
## CONFIGURATION
## ============================================================================

ecoregion_id <- 5

projections_dir <- file.path("/media/steve/THREDDS/data/MACA/sien/projections", model, scenario)
thresholds <- c(0.50, 0.75, 0.90, 0.95)

## ============================================================================
## LOAD CLASSIFIED COVER
## ============================================================================

message("Loading classified cover raster...")
classified_rast <- rast(glue("data/classified_cover/ecoregion_{ecoregion_id}_classified.tif"))

## Project to match MACA CRS (0-360 longitude)
## Use a fire danger file as template for the target CRS
sample_files <- list.files(projections_dir, pattern = "_fire_danger_forest\\.nc$", full.names = TRUE)
if (length(sample_files) == 0) stop(glue("No fire danger files found in {projections_dir}"))
maca_crs <- crs(rast(sample_files[1]))
classified_rast <- project(classified_rast, maca_crs)

## ============================================================================
## FIND YEARS TO PROCESS
## ============================================================================

forest_files <- sort(list.files(projections_dir, pattern = "_fire_danger_forest\\.nc$"))
available_years <- as.integer(gsub("_fire_danger_forest\\.nc$", "", forest_files))

if (!is.null(start_year)) available_years <- available_years[available_years >= start_year]
if (!is.null(end_year)) available_years <- available_years[available_years <= end_year]

message(glue("Years to process: {min(available_years)}-{max(available_years)} ({length(available_years)} years)"))

## ============================================================================
## PROCESS EACH YEAR
## ============================================================================

for (yr in available_years) {
  yr_start <- Sys.time()

  forest_file <- file.path(projections_dir, glue("{yr}_fire_danger_forest.nc"))
  non_forest_file <- file.path(projections_dir, glue("{yr}_fire_danger_non_forest.nc"))
  threshold_file <- file.path(projections_dir, glue("{yr}_days_above_thresholds.tif"))

  if (file.exists(threshold_file)) {
    message(glue("  {yr}: already exists, skipping."))
    next
  }

  if (!file.exists(forest_file) || !file.exists(non_forest_file)) {
    message(glue("  {yr}: missing fire danger files, skipping."))
    next
  }

  message(glue("--- Year {yr} ---"))

  forest_daily <- rast(forest_file)
  non_forest_daily <- rast(non_forest_file)

  threshold_layers <- list()
  for (thresh in thresholds) {
    ## Count days above threshold at MACA resolution (fast)
    forest_days <- app(forest_daily > thresh, fun = sum, na.rm = TRUE)
    nonforest_days <- app(non_forest_daily > thresh, fun = sum, na.rm = TRUE)

    ## Resample single-layer results to classified cover resolution (30m)
    ## Nearest-neighbor preserves integer day-counts (bilinear creates fractional values)
    forest_days_hr <- resample(forest_days, classified_rast, method = "near")
    nonforest_days_hr <- resample(nonforest_days, classified_rast, method = "near")

    ## Combine via cover type
    combined <- ifel(classified_rast == "forest", forest_days_hr, nonforest_days_hr)
    combined <- mask(combined, !is.na(classified_rast), maskvalues = FALSE)
    names(combined) <- glue("days_above_{thresh}")
    threshold_layers <- c(threshold_layers, list(combined))
  }

  ## Write as GeoTIFF (preserves CRS, better compression for categorical-ish data)
  out_rast <- rast(threshold_layers)
  writeRaster(out_rast, threshold_file, overwrite = TRUE, datatype = "INT2U",
              gdal = c("COMPRESS=DEFLATE", "ZLEVEL=9"))

  rm(forest_daily, non_forest_daily, threshold_layers, out_rast)
  gc()

  yr_elapsed <- round(difftime(Sys.time(), yr_start, units = "mins"), 1)
  fsize <- round(file.size(threshold_file) / 1024 / 1024, 1)
  message(glue("  Year {yr} complete in {yr_elapsed} min ({fsize} MB)"))
}

elapsed <- round(difftime(Sys.time(), start_time, units = "hours"), 2)
message(glue("========================================"))
message(glue("Threshold computation complete: {model} {scenario}"))
message(glue("Elapsed time: {elapsed} hours"))
message(glue("========================================"))
