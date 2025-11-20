## Generate quantile rasters for Mojave Basin and Range using GDD_0 (Growing Degree Days, base 0)
## Non-forest only: 27-day rolling sum
##
## GDD_0 is calculated as (Tmax + Tmin) / 2, which represents daily heat accumulation.
## For fire danger prediction, we use a 27-day rolling sum to capture cumulative warmth.

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)

message("========================================")
message("Generating Mojave Basin and Range GDD_0 quantile rasters")
message("========================================")

terraOptions(
  verbose = TRUE,
  memfrac = 0.9
)

probs <- seq(.01, 1.0, by = .01)

# Load Mojave Basin and Range boundary
message("Loading Mojave Basin and Range boundary...")
mojave <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Mojave Basin and Range")

# Load gridMET temperature data
message("Loading gridMET tmax and tmin historical data...")
gridmet_data_dir <- "/media/steve/THREDDS/gridmet/"

# Load tmax files
tmax_files <- list.files(gridmet_data_dir, pattern = "tmmx_.*.nc", full.names = TRUE)
message(glue("Found {length(tmax_files)} tmax files"))

tmax_data <- rast(tmax_files) %>%
  crop(project(mojave, crs(.))) %>%
  mask(project(mojave, crs(.)))

time(tmax_data) <- as_date(depth(tmax_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(tmax_data)} days of tmax data"))

# Load tmin files
tmin_files <- list.files(gridmet_data_dir, pattern = "tmmn_.*.nc", full.names = TRUE)
message(glue("Found {length(tmin_files)} tmin files"))

tmin_data <- rast(tmin_files) %>%
  crop(project(mojave, crs(.))) %>%
  mask(project(mojave, crs(.)))

time(tmin_data) <- as_date(depth(tmin_data), origin = "1900-01-01")
message(glue("Loaded {nlyr(tmin_data)} days of tmin data"))

# Verify tmax and tmin have same dates
if (!identical(time(tmax_data), time(tmin_data))) {
  stop("ERROR: tmax and tmin data have different dates. Cannot calculate GDD_0.")
}

# Calculate GDD_0 = (Tmax + Tmin) / 2
# Note: gridMET temperatures are in Kelvin, but since we're taking differences
# for percentile calculations, the units cancel out
message("Calculating GDD_0 = (Tmax + Tmin) / 2...")
gdd_0_data <- (tmax_data + tmin_data) / 2

message(glue("Calculated {nlyr(gdd_0_data)} days of GDD_0 data"))

# Create output directory
dir.create("./data/ecdf/14-mojave_basin_and_range-non_forest", showWarnings = FALSE, recursive = TRUE)

# Non-forest quantiles (27-day rolling sum)
message("========================================")
message("Computing non-forest quantiles (27-day rolling SUM)...")
message("This may take a while for CONUS-scale data...")
message("========================================")

# IMPORTANT: GDD uses rolling SUM (not mean) because we're interested in cumulative heat
# NOTE: GDD_0 uses dplyr::percent_rank() in 03_dryness.R (flux_vars)
# which does NOT round, substitute zeros, or remove duplicates.
# Do not apply those transformations here to match the eCDF training data.
non_forest_quants_rast <- terra::roll(gdd_0_data, n = 27, fun = sum, type = "to", circular = FALSE) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

message("Writing non-forest quantile raster...")
writeCDF(
  non_forest_quants_rast,
  "./data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-quants.nc",
  overwrite = TRUE,
  split = TRUE
)
message("✓ Non-forest quantile raster saved")

message("========================================")
message("Quantile raster generation complete!")
message("========================================")
message("Output file:")
message("  - data/ecdf/14-mojave_basin_and_range-non_forest/14-mojave_basin_and_range-non_forest-27-GDD_0-quants.nc")
message("")
message("Next steps:")
message("  1. Generate eCDF model using src/retrospective/04_model_generation/generate_ecdf_general.R")
message("  2. Update forecast download script for tmax/tmin")
message("  3. Refactor map_forecast_danger.R for GDD_0 support")
