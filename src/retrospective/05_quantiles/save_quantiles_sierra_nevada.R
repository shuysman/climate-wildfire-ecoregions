## Generate quantile rasters for Sierra Nevada (ecoregion 5)
## Forest: 3-day rolling MEAN VPD
## Non-forest: 17-day rolling MEAN VPD

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
## NON-FOREST: 17-day rolling MEAN VPD
## ============================================================================

message("========================================")
message("NON-FOREST: Loading gridMET VPD data...")
message("========================================")

## Reload VPD data (was freed after forest section)
vpd_data <- rast(vpd_data_files) %>%
  crop(project(sierra_nevada, crs(.))) %>%
  mask(project(sierra_nevada, crs(.)))

time(vpd_data) <- as_date(depth(vpd_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(vpd_data)} days of VPD data"))

message("Computing non-forest quantiles (17-day rolling MEAN)...")
## VPD is a state variable: round, substitute zeros, remove duplicates before quantile
non_forest_quants_rast <- terra::roll(vpd_data, n = 17, fun = mean, type = "to", circular = FALSE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

dir.create("./data/ecdf/5-sierra_nevada-non_forest", showWarnings = FALSE, recursive = TRUE)
writeCDF(
  non_forest_quants_rast,
  "./data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-17-VPD-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("  Non-forest VPD quantile raster saved")

message("========================================")
message("Quantile raster generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/5-sierra_nevada-forest/5-sierra_nevada-forest-3-VPD-quants.nc")
message("  - data/ecdf/5-sierra_nevada-non_forest/5-sierra_nevada-non_forest-17-VPD-quants.nc")
