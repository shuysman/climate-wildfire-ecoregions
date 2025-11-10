## Generate quantile rasters for Southern Rockies using inverted FM1000 (100 - FM1000)
## Forest: 5-day rolling mean
## Non-forest: 1-day (no rolling average)
##
## IMPORTANT: FM1000 is inverted (100 - FM1000) so that the relationship matches other
## variables: higher inverted FM1000 = higher fire risk (lower moisture). This ensures
## percentile calculations map correctly through the eCDF to fire danger.

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)

message("========================================")
message("Generating Southern Rockies quantile rasters")
message("========================================")

terraOptions(
  verbose = TRUE,
  memfrac = 0.9
)

probs <- seq(.01, 1.0, by = .01)

# Load Southern Rockies boundary
message("Loading Southern Rockies boundary...")
southern_rockies <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Southern Rockies")

# Load FM1000 historical data
message("Loading FM1000 historical data...")
fm1000_data_dir <- "/media/steve/THREDDS/gridmet/"
fm1000_data_files <- list.files(fm1000_data_dir, pattern = "fm1000_.*.nc", full.names = TRUE)

message(glue("Found {length(fm1000_data_files)} FM1000 files"))

fm1000_data <- rast(fm1000_data_files) %>%
  crop(project(southern_rockies, crs(.))) %>%
  mask(project(southern_rockies, crs(.)))

time(fm1000_data) <- as_date(depth(fm1000_data), origin = "1900-01-01")

message(glue("Loaded {nlyr(fm1000_data)} days of FM1000 data"))

# Invert FM1000: higher moisture (lower fire risk) -> lower inverted value (lower percentile)
# This inverts the relationship so that higher inverted FM1000 = higher fire risk (matching other variables)
message("Inverting FM1000 to (100 - FM1000) for correct fire risk relationship...")
fm1000_data <- 100 - fm1000_data

# Create output directories
dir.create("./data/ecdf/21-southern_rockies-forest", showWarnings = FALSE, recursive = TRUE)
dir.create("./data/ecdf/21-southern_rockies-non_forest", showWarnings = FALSE, recursive = TRUE)

# Forest quantiles (5-day rolling mean)
message("========================================")
message("Computing forest quantiles (5-day rolling mean)...")
message("========================================")

# NOTE: FM1000 uses dplyr::percent_rank() in 03_dryness.R (state_vars_no_floor)
# which does NOT round, substitute zeros, or remove duplicates.
# Do not apply those transformations here to match the eCDF training data.
forest_quants_rast <- terra::roll(fm1000_data, n = 5, fun = mean, type = "to", circular = FALSE) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

message("Writing forest quantile raster...")
writeCDF(
  forest_quants_rast,
  "./data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("✓ Forest quantile raster saved")

# Non-forest quantiles (1-day, no rolling average)
message("========================================")
message("Computing non-forest quantiles (1-day)...")
message("========================================")

# For 1-day window, we just use the data directly (no rolling average)
# NOTE: FM1000 uses dplyr::percent_rank() in 03_dryness.R (state_vars_no_floor)
# which does NOT round, substitute zeros, or remove duplicates.
# Do not apply those transformations here to match the eCDF training data.
non_forest_quants_rast <- fm1000_data %>%
  terra::quantile(probs = probs, na.rm = TRUE)

message("Writing non-forest quantile raster...")
writeCDF(
  non_forest_quants_rast,
  "./data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("✓ Non-forest quantile raster saved")

message("========================================")
message("Quantile raster generation complete!")
message("========================================")
message("Output files:")
message("  - data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-quants.nc")
message("  - data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-quants.nc")
