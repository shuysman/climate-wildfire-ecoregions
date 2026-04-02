## Project fire danger for Sierra Nevada using MACA climate projections
##
## Applies the pyrome-fire eCDF methodology to MACA CMIP5 projections:
## 1. Load precomputed rolled VPD and GDD_15 (from precompute_gdd15.sh)
## 2. Align grids and dates
## 3. Process year-by-year: percentile binning → eCDF → fire danger
## 4. Save separate forest/non-forest daily fire danger rasters
## Threshold summaries (days-above) are computed as a separate post-processing step
##
## Usage: Rscript project_fire_danger.R <model> <scenario>
## Example: Rscript project_fire_danger.R BNU-ESM rcp45

library(terra)
library(glue)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript project_fire_danger.R <model> <scenario>")
}

model <- args[1]
scenario <- args[2]

message(glue("========================================"))
message(glue("Sierra Nevada Fire Danger Projections"))
message(glue("Model: {model}  Scenario: {scenario}"))
message(glue("========================================"))

start_time <- Sys.time()

terraOptions(verbose = FALSE, memfrac = 0.9)

## ============================================================================
## CONFIGURATION
## ============================================================================

ecoregion_id <- 5
ecoregion_name_clean <- "sierra_nevada"

## Predictor configuration (from eCDF model selection)
forest_window <- 3
forest_variable <- "vpd"
non_forest_window <- 26
non_forest_variable <- "gdd_15"

## Paths
maca_data_dir <- "/media/steve/THREDDS/data/MACA/sien/forecasts/daily"
out_base_dir <- "/media/steve/THREDDS/data/MACA/sien/projections"

probs <- seq(.01, 1.0, by = .01)

## ============================================================================
## HELPER FUNCTIONS (from map_forecast_danger.R)
## ============================================================================

bin_rast <- function(new_rast, quants_rast, probs) {
  bin_index_rast <- sum(new_rast > quants_rast)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)
  classify(bin_index_rast, rcl = rcl_matrix)
}

process_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, forest_quants_rast, probs)
  terra::app(percentile_rast, fun = forest_fire_danger_ecdf)
}

process_non_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, non_forest_quants_rast, probs)
  terra::app(percentile_rast, fun = non_forest_fire_danger_ecdf)
}

## ============================================================================
## LOAD STATIC DATA
## ============================================================================

message("Loading eCDF models...")
forest_ecdf_path <- glue("data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-ecdf.RDS")
non_forest_ecdf_path <- glue("data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-ecdf.RDS")

forest_fire_danger_ecdf <- readRDS(forest_ecdf_path)
non_forest_fire_danger_ecdf <- readRDS(non_forest_ecdf_path)

message("Loading quantile rasters...")
forest_quants_path <- glue("data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-quants.nc")
non_forest_quants_path <- glue("data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-quants.nc")

forest_quants_rast <- rast(forest_quants_path)
non_forest_quants_rast <- rast(non_forest_quants_path)

## ============================================================================
## LOAD ALL MACA DATA AND COMPUTE DERIVED VARIABLES
## ============================================================================

## Load precomputed rolled data (from precompute_gdd15.sh)
## VPD: 3-day rolling mean, GDD_15: 26-day rolling sum
message("Loading precomputed rolled VPD (3-day mean)...")
vpd_rolled_file <- file.path(maca_data_dir, glue("vpd_rolled_{forest_window}_{model}_{scenario}_2006-2099_daily_sien.nc"))
gdd15_rolled_file <- file.path(maca_data_dir, glue("gdd15_rolled_{non_forest_window}_{model}_{scenario}_2006-2099_daily_sien.nc"))

for (f in c(vpd_rolled_file, gdd15_rolled_file)) {
  if (!file.exists(f)) stop(glue("File not found: {f}\nRun precompute_gdd15.sh first."))
}

forest_rolled <- rast(vpd_rolled_file)
message(glue("  VPD rolled: {nlyr(forest_rolled)} days"))

message("Loading precomputed rolled GDD_15 (26-day sum)...")
non_forest_rolled <- rast(gdd15_rolled_file)
message(glue("  GDD_15 rolled: {nlyr(non_forest_rolled)} days"))

## Align grids: MACA uses 0-360 longitude, quantile rasters use -180 to 180
## Resample quantile rasters (100 layers each) to match MACA grid (much faster than resampling 34k layers)
message("Aligning quantile rasters to MACA grid...")
maca_template <- subset(forest_rolled, 1)
forest_quants_rast <- project(forest_quants_rast, maca_template)
non_forest_quants_rast <- project(non_forest_quants_rast, maca_template)

load_elapsed <- round(difftime(Sys.time(), start_time, units = "mins"), 1)
message(glue("Data loading complete in {load_elapsed} min"))

## ============================================================================
## ALIGN DATES — CDO runsum/runmean trim different amounts from the start
## Use intersection of dates present in both rolled datasets
## ============================================================================

forest_dates <- time(forest_rolled)
non_forest_dates <- time(non_forest_rolled)
common_dates <- intersect(forest_dates, non_forest_dates)
common_dates <- sort(as.Date(common_dates, origin = "1970-01-01"))

message(glue("  Forest layers: {length(forest_dates)}, Non-forest layers: {length(non_forest_dates)}, Common: {length(common_dates)}"))

## Subset both to common dates
forest_rolled <- subset(forest_rolled, which(forest_dates %in% common_dates))
non_forest_rolled <- subset(non_forest_rolled, which(non_forest_dates %in% common_dates))

## ============================================================================
## PROCESS YEAR BY YEAR
## ============================================================================

all_dates <- common_dates
years <- unique(as.integer(format(all_dates, "%Y")))

out_dir <- file.path(out_base_dir, model, scenario)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

for (yr in years) {
  yr_start <- Sys.time()
  message(glue("--- Year {yr} ---"))

  forest_daily_file <- file.path(out_dir, glue("{yr}_fire_danger_forest.nc"))
  non_forest_daily_file <- file.path(out_dir, glue("{yr}_fire_danger_non_forest.nc"))

  if (file.exists(forest_daily_file) && file.exists(non_forest_daily_file)) {
    message("  Already processed, skipping.")
    next
  }

  year_mask <- format(all_dates, "%Y") == as.character(yr)
  year_dates <- all_dates[year_mask]
  year_idx <- which(year_mask)

  if (length(year_dates) == 0) next

  forest_year <- subset(forest_rolled, year_idx)
  non_forest_year <- subset(non_forest_rolled, year_idx)

  ## Process each day — keep forest and non-forest separate
  forest_daily_layers <- vector("list", length(year_dates))
  non_forest_daily_layers <- vector("list", length(year_dates))

  for (i in seq_along(year_dates)) {
    forest_daily_layers[[i]] <- process_forest_layer(subset(forest_year, i))
    non_forest_daily_layers[[i]] <- process_non_forest_layer(subset(non_forest_year, i))

    if (i %% 100 == 0) message(glue("    Day {i}/{length(year_dates)}"))
  }

  ## Stack per cover type
  forest_daily_rast <- rast(forest_daily_layers)
  time(forest_daily_rast) <- year_dates
  names(forest_daily_rast) <- as.character(year_dates)

  non_forest_daily_rast <- rast(non_forest_daily_layers)
  time(non_forest_daily_rast) <- year_dates
  names(non_forest_daily_rast) <- as.character(year_dates)

  ## Save separate daily fire danger rasters per cover type
  writeCDF(forest_daily_rast, forest_daily_file, overwrite = TRUE, varname = "fire_danger_forest", compression = 2)
  writeCDF(non_forest_daily_rast, non_forest_daily_file, overwrite = TRUE, varname = "fire_danger_non_forest", compression = 2)

  rm(forest_daily_rast, non_forest_daily_rast, forest_daily_layers, non_forest_daily_layers,
     forest_year, non_forest_year)
  gc()

  yr_elapsed <- round(difftime(Sys.time(), yr_start, units = "mins"), 1)
  message(glue("  Year {yr} complete in {yr_elapsed} min"))
}

end_time <- Sys.time()
elapsed <- round(difftime(end_time, start_time, units = "hours"), 2)
message(glue("========================================"))
message(glue("Projection complete: {model} {scenario}"))
message(glue("Elapsed time: {elapsed} hours"))
message(glue("Output: {out_dir}"))
message(glue("========================================"))
