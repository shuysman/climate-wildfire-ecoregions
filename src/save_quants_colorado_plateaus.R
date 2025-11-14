## Generate quantile rasters for Colorado Plateaus using two different variables:
## - Forest: Inverted FM1000 (100 - FM1000), 5-day rolling mean
## - Non-forest: VPD, 27-day rolling mean
##
## This is the FIRST ecoregion using different predictors for forest vs non-forest!
##
## IMPORTANT: Variable preprocessing methods must match 03_dryness.R:
## - VPD uses my_percent_rank(): round(1), subst(0, NA), remove duplicates
## - FM1000 uses dplyr::percent_rank(): NO transformations

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)

message("========================================")
message("Generating Colorado Plateaus quantile rasters")
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

# Load Colorado Plateaus boundary
message("Loading Colorado Plateaus boundary...")
colorado_plateaus <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Colorado Plateaus")

# Create output directories
dir.create("./data/ecdf/20-colorado_plateaus-forest", showWarnings = FALSE, recursive = TRUE)
dir.create("./data/ecdf/20-colorado_plateaus-non_forest", showWarnings = FALSE, recursive = TRUE)

# ============================================================================
# FOREST: FM1000 inverted (5-day rolling mean)
# ============================================================================

message("========================================")
message("Processing FOREST: FM1000 inverted (5-day rolling mean)")
message("========================================")

# Load FM1000 historical data
message("Loading FM1000 historical data...")
fm1000_data_dir <- "/media/steve/THREDDS/gridmet/"
fm1000_data_files <- list.files(fm1000_data_dir, pattern = "fm1000_.*.nc", full.names = TRUE)

message(glue("Found {length(fm1000_data_files)} FM1000 files"))

fm1000_data <- rast(fm1000_data_files) %>%
  crop(project(colorado_plateaus, crs(.))) %>%
  mask(project(colorado_plateaus, crs(.)))

time(fm1000_data) <- as_date(depth(fm1000_data), origin = "1900-01-01")

message(glue("Loaded {nlyr(fm1000_data)} days of FM1000 data"))

# Invert FM1000: higher moisture (lower fire risk) -> lower inverted value (lower percentile)
# This inverts the relationship so that higher inverted FM1000 = higher fire risk (matching other variables)
message("Inverting FM1000 to (100 - FM1000) for correct fire risk relationship...")
fm1000_data <- 100 - fm1000_data

# Forest quantiles (5-day rolling mean)
message("Computing forest quantiles (5-day rolling mean)...")

# NOTE: FM1000 uses dplyr::percent_rank() in 03_dryness.R (state_vars_no_floor)
# which does NOT round, substitute zeros, or remove duplicates.
# Do not apply those transformations here to match the eCDF training data.
forest_quants_rast <- terra::roll(fm1000_data, n = 5, fun = mean, type = "to", circular = FALSE) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

message("Writing forest quantile raster...")
writeCDF(
  forest_quants_rast,
  "./data/ecdf/20-colorado_plateaus-forest/20-colorado_plateaus-forest-5-FM1000INV-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("✓ Forest quantile raster saved")

# Clear memory
rm(fm1000_data)
gc()

# ============================================================================
# NON-FOREST: VPD (27-day rolling mean)
# ============================================================================

message("========================================")
message("Processing NON-FOREST: VPD (27-day rolling mean)")
message("========================================")

# Load VPD historical data
message("Loading VPD historical data...")
vpd_data_dir <- "/media/steve/THREDDS/gridmet/"
vpd_data_files <- list.files(vpd_data_dir, pattern = "vpd.*.nc", full.names = TRUE)

message(glue("Found {length(vpd_data_files)} VPD files"))

vpd_data <- rast(vpd_data_files) %>%
  crop(project(colorado_plateaus, crs(.))) %>%
  mask(project(colorado_plateaus, crs(.)))

time(vpd_data) <- as_date(depth(vpd_data), origin = "1900-01-01")

message(glue("Loaded {nlyr(vpd_data)} days of VPD data"))

# Non-forest quantiles (27-day rolling mean)
message("Computing non-forest quantiles (27-day rolling mean)...")

# NOTE: VPD uses my_percent_rank() in 03_dryness.R (state_vars)
# which rounds to 1 decimal, substitutes zeros with NA, and removes duplicates.
# Apply those same transformations here to match the eCDF training data.
non_forest_quants_rast <- terra::roll(vpd_data, n = 27, fun = mean, type = "to", circular = FALSE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

message("Writing non-forest quantile raster...")
writeCDF(
  non_forest_quants_rast,
  "./data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("✓ Non-forest quantile raster saved")

message("========================================")
message("Quantile raster generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/20-colorado_plateaus-forest/20-colorado_plateaus-forest-5-FM1000INV-quants.nc")
message("  - data/ecdf/20-colorado_plateaus-non_forest/20-colorado_plateaus-non_forest-27-VPD-quants.nc")
