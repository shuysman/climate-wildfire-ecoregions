## Generate quantile rasters for Sierra Nevada (ecoregion 5)
## Forest: 3-day rolling MEAN VPD
## Non-forest: 26-day rolling SUM GDD_15
##
## GDD_15 = max(0, (Tmax + Tmin) / 2 - 273.15 - 15)
## gridMET temps are in Kelvin; convert to Celsius, subtract base temp 15, clamp negatives to 0

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)

message("========================================")
message("Generating Sierra Nevada quantile rasters")
message("========================================")

replace_duplicated <- function(x) {
  x[duplicated(x)] <- NA
  return(x)
}

terraOptions(
  verbose = TRUE,
  memfrac = 0.9
)

probs <- seq(.01, 1.0, by = .01)

## Load Sierra Nevada boundary
message("Loading Sierra Nevada boundary...")
sierra_nevada <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Sierra Nevada")

gridmet_data_dir <- "/media/steve/THREDDS/gridmet/"

## ============================================================================
## FOREST: 3-day rolling MEAN VPD
## ============================================================================

message("========================================")
message("FOREST: Loading gridMET VPD data...")
message("========================================")

vpd_data_files <- list.files(gridmet_data_dir, pattern = "vpd_.*.nc", full.names = TRUE)
message(glue("Found {length(vpd_data_files)} VPD files"))

vpd_data <- rast(vpd_data_files) %>%
  crop(project(sierra_nevada, crs(.))) %>%
  mask(project(sierra_nevada, crs(.)))

time(vpd_data) <- as_date(depth(vpd_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(vpd_data)} days of VPD data"))

message("Computing forest quantiles (3-day rolling MEAN)...")
## VPD is a state variable: round, substitute zeros, remove duplicates before quantile
## This matches the eCDF training data processing in dryness_roc_analysis.R
forest_quants_rast <- terra::roll(vpd_data, n = 3, fun = mean, type = "to", circular = FALSE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

dir.create("./data/ecdf/5-sierra_nevada-forest", showWarnings = FALSE, recursive = TRUE)
writeCDF(
  forest_quants_rast,
  "./data/ecdf/5-sierra_nevada-forest/5-sierra_nevada-forest-3-VPD-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("  Forest VPD quantile raster saved")

## Free memory
rm(vpd_data, forest_quants_rast)
gc()

## ============================================================================
## NON-FOREST: 26-day rolling SUM GDD_15
## ============================================================================

message("========================================")
message("NON-FOREST: Loading gridMET temperature data...")
message("========================================")

tmax_files <- list.files(gridmet_data_dir, pattern = "tmmx_.*.nc", full.names = TRUE)
message(glue("Found {length(tmax_files)} tmax files"))

tmax_data <- rast(tmax_files) %>%
  crop(project(sierra_nevada, crs(.))) %>%
  mask(project(sierra_nevada, crs(.)))

time(tmax_data) <- as_date(depth(tmax_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(tmax_data)} days of tmax data"))

tmin_files <- list.files(gridmet_data_dir, pattern = "tmmn_.*.nc", full.names = TRUE)
message(glue("Found {length(tmin_files)} tmin files"))

tmin_data <- rast(tmin_files) %>%
  crop(project(sierra_nevada, crs(.))) %>%
  mask(project(sierra_nevada, crs(.)))

time(tmin_data) <- as_date(depth(tmin_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(tmin_data)} days of tmin data"))

## Verify tmax and tmin have same dates
if (!identical(time(tmax_data), time(tmin_data))) {
  stop("ERROR: tmax and tmin data have different dates. Cannot calculate GDD_15.")
}

## Calculate GDD_15 = max(0, (Tmax + Tmin) / 2 - 273.15 - 15)
## gridMET temperatures are in Kelvin
message("Calculating GDD_15 from Kelvin temps (convert to C, subtract base 15, clamp to 0)...")
gdd_15_data <- (tmax_data + tmin_data) / 2 - 273.15 - 15
gdd_15_data <- clamp(gdd_15_data, lower = 0)

message(glue("Calculated {nlyr(gdd_15_data)} days of GDD_15 data"))

## Free temperature rasters
rm(tmax_data, tmin_data)
gc()

message("Computing non-forest quantiles (26-day rolling SUM)...")
## GDD_15 is in flux_vars in dryness_roc_analysis.R, so it uses my_percent_rank():
## round to 1 decimal, treat zeros as NA, then drop duplicated values before
## calculating percentiles. Apply the same preprocessing here so the quantile
## breakpoints match the retrospective eCDF training data and forecast pipeline.
non_forest_quants_rast <- terra::roll(gdd_15_data, n = 26, fun = sum, type = "to", circular = FALSE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

dir.create("./data/ecdf/5-sierra_nevada-non_forest", showWarnings = FALSE, recursive = TRUE)
writeCDF(
  non_forest_quants_rast,
  "./data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-26-GDD_15-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("  Non-forest GDD_15 quantile raster saved")

message("========================================")
message("Quantile raster generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/5-sierra_nevada-forest/5-sierra_nevada-forest-3-VPD-quants.nc")
message("  - data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-26-GDD_15-quants.nc")
