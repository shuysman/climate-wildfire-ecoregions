#!/usr/bin/env Rscript
## Validate Southern Rockies Fire Danger Forecast
##
## The Southern Rockies is showing zero fire danger for the entire forecast period.
## This script validates whether this is accurate by:
## 1. Checking the raw FM1000 forecast values
## 2. Comparing to the FM1000INV quantile rasters
## 3. Verifying the eCDF mapping is working correctly
## 4. Comparing to historical fire conditions

library(terra)
library(tidyverse)
library(glue)
library(yaml)

message("========================================")
message("Southern Rockies Fire Danger Validation")
message("========================================")
message("")

# Load config
config <- read_yaml("config/ecoregions.yaml")
sr_config <- config$ecoregions[[which(sapply(config$ecoregions, function(x) x$name_clean == "southern_rockies"))]]

message("Southern Rockies Configuration:")
message(glue("  Forest: {sr_config$cover_types$forest$window}-day {sr_config$cover_types$forest$variable}"))
message(glue("  Non-forest: {sr_config$cover_types$non_forest$window}-day {sr_config$cover_types$non_forest$variable}"))
message("")

# Check if forecast output exists
today <- Sys.Date()
forecast_dir <- glue("out/forecasts/southern_rockies/{today}")

if (!dir.exists(forecast_dir)) {
  stop(glue("No forecast found for today ({today}). Run the forecast first."))
}

forecast_nc <- glue("{forecast_dir}/fire_danger_forecast.nc")
if (!file.exists(forecast_nc)) {
  stop(glue("Forecast NetCDF not found: {forecast_nc}"))
}

message("Loading forecast output...")
forecast_rast <- rast(forecast_nc)
message(glue("  Layers: {nlyr(forecast_rast)}"))
message(glue("  Expected: 2 layers per day (variable percentile + fire danger)"))
message("")

# Extract fire danger layers (even numbered layers: 2, 4, 6, 8...)
n_days <- nlyr(forecast_rast) / 2
fire_danger_layers <- seq(2, nlyr(forecast_rast), by = 2)
fire_danger <- subset(forecast_rast, fire_danger_layers)

message("Fire Danger Statistics by Forecast Day:")
message("=========================================")

for (i in 1:nlyr(fire_danger)) {
  layer <- fire_danger[[i]]
  vals <- values(layer, na.rm = TRUE)

  message(glue("Day {i-1}:"))
  message(glue("  Min: {round(min(vals), 4)}"))
  message(glue("  Max: {round(max(vals), 4)}"))
  message(glue("  Mean: {round(mean(vals), 4)}"))
  message(glue("  Cells > 0: {sum(vals > 0)} ({round(100*sum(vals > 0)/length(vals), 1)}%)"))
  message(glue("  Cells > 0.5: {sum(vals > 0.5)} ({round(100*sum(vals > 0.5)/length(vals), 1)}%)"))
  message("")
}

# Now check the raw FM1000 values
message("========================================")
message("Checking Raw FM1000 Forecast Values")
message("========================================")
message("")

fm1000_forecast_file <- "data/forecasts/fm1000/cfsv2_metdata_forecast_fm1000_daily_0.nc"

if (!file.exists(fm1000_forecast_file)) {
  message("WARNING: FM1000 forecast file not found. Download forecasts first.")
  message(glue("Expected: {fm1000_forecast_file}"))
} else {
  # Load FM1000 forecast
  fm1000_rast <- rast(fm1000_forecast_file)

  # Invert (100 - FM1000) as done in map_forecast_danger.R
  message("Inverting FM1000 to (100 - FM1000)...")
  fm1000inv_rast <- 100 - fm1000_rast

  # Load Southern Rockies boundary
  sr_boundary_all <- vect("data/us_eco_l3/us_eco_l3.shp")
  sr_boundary <- sr_boundary_all[sr_boundary_all$US_L3NAME == "Southern Rockies", ]

  # Crop to Southern Rockies
  fm1000inv_sr <- crop(fm1000inv_rast, project(sr_boundary, crs(fm1000inv_rast)))
  fm1000inv_sr <- mask(fm1000inv_sr, project(sr_boundary, crs(fm1000inv_rast)))

  message("FM1000INV Statistics for Southern Rockies:")
  message("===========================================")

  for (i in 1:min(8, nlyr(fm1000inv_sr))) {
    layer <- fm1000inv_sr[[i]]
    vals <- values(layer, na.rm = TRUE)

    message(glue("Day {i-1}:"))
    message(glue("  Min: {round(min(vals), 2)}"))
    message(glue("  Max: {round(max(vals), 2)}"))
    message(glue("  Mean: {round(mean(vals), 2)}"))
    message(glue("  Median: {round(median(vals), 2)}"))
    message("")
  }

  # Check quantile rasters
  message("========================================")
  message("Checking FM1000INV Quantile Rasters")
  message("========================================")
  message("")

  forest_quants_file <- "data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-quants.nc"
  nonforest_quants_file <- "data/ecdf/21-southern_rockies-non_forest/21-southern_rockies-non_forest-1-FM1000INV-quants.nc"

  if (file.exists(forest_quants_file)) {
    forest_quants <- rast(forest_quants_file)
    message("Forest quantile rasters loaded:")
    message(glue("  Layers (percentiles): {nlyr(forest_quants)}"))

    # Get a sample location
    sample_point <- as.points(sr_boundary, values = FALSE)[1]

    # Extract quantile values at sample point
    quant_vals <- extract(forest_quants, project(sample_point, crs(forest_quants)))[1,]

    # Show selected percentiles
    percentiles <- c(1, 10, 25, 50, 75, 90, 99)
    message("Sample location FM1000INV quantiles (forest):")
    for (p in percentiles) {
      layer_idx <- p
      val <- quant_vals[layer_idx]
      message(glue("  {p}th percentile: {round(val, 2)}"))
    }
    message("")

    # Compare to current forecast
    if (exists("fm1000inv_sr")) {
      # Get 5-day rolling mean (forest window)
      if (nlyr(fm1000inv_sr) >= 5) {
        fm1000_5day <- roll(fm1000inv_sr, n = 5, fun = mean, type = "to", circular = FALSE)
        current_val <- extract(fm1000_5day[[1]], project(sample_point, crs(fm1000_5day)))[1,1]

        message(glue("Current 5-day FM1000INV at sample location: {round(current_val, 2)}"))

        # Find which percentile this corresponds to
        percentile_rank <- sum(quant_vals < current_val, na.rm = TRUE)
        message(glue("This is approximately the {percentile_rank}th percentile"))

        if (percentile_rank < 50) {
          message("")
          message("⚠ WARNING: Current FM1000INV is BELOW median!")
          message("   This indicates HIGH fuel moisture (LOW fire risk)")
          message("   Zero fire danger forecast may be CORRECT")
        } else if (percentile_rank > 75) {
          message("")
          message("✗ ERROR: Current FM1000INV is ABOVE 75th percentile!")
          message("   This indicates LOW fuel moisture (HIGH fire risk)")
          message("   Zero fire danger forecast is INCORRECT")
        }
      }
    }
  }

  # Load and check eCDF
  message("")
  message("========================================")
  message("Checking eCDF Mapping")
  message("========================================")
  message("")

  forest_ecdf_file <- "data/ecdf/21-southern_rockies-forest/21-southern_rockies-forest-5-FM1000INV-ecdf.RDS"

  if (file.exists(forest_ecdf_file)) {
    forest_ecdf <- readRDS(forest_ecdf_file)

    message("eCDF function loaded")
    message("Testing percentile -> fire danger mapping:")

    test_percentiles <- c(0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99)
    for (p in test_percentiles) {
      fire_danger <- forest_ecdf(p)
      message(glue("  {round(p*100)}th percentile -> Fire danger: {round(fire_danger, 4)}"))
    }

    message("")
    message("eCDF interpretation:")
    message("  Low percentiles (wet conditions) should map to LOW fire danger")
    message("  High percentiles (dry conditions) should map to HIGH fire danger")
  }
}

# Compare to Middle Rockies
message("")
message("========================================")
message("Comparison: Middle Rockies vs Southern Rockies")
message("========================================")
message("")

mr_forecast_nc <- glue("out/forecasts/middle_rockies/{today}/fire_danger_forecast.nc")
if (file.exists(mr_forecast_nc)) {
  mr_forecast <- rast(mr_forecast_nc)
  mr_fire_danger <- subset(mr_forecast, seq(2, nlyr(mr_forecast), by = 2))

  message("Middle Rockies Fire Danger:")
  for (i in 1:min(3, nlyr(mr_fire_danger))) {
    vals <- values(mr_fire_danger[[i]], na.rm = TRUE)
    message(glue("Day {i-1}: Mean = {round(mean(vals), 4)}, Cells > 0 = {sum(vals > 0)} ({round(100*sum(vals > 0)/length(vals), 1)}%)"))
  }

  message("")
  message("Southern Rockies Fire Danger:")
  for (i in 1:min(3, nlyr(fire_danger))) {
    vals <- values(fire_danger[[i]], na.rm = TRUE)
    message(glue("Day {i-1}: Mean = {round(mean(vals), 4)}, Cells > 0 = {sum(vals > 0)} ({round(100*sum(vals > 0)/length(vals), 1)}%)"))
  }

  message("")
  message("Interpretation:")
  message("  Middle Rockies uses VPD (atmospheric dryness)")
  message("  Southern Rockies uses FM1000INV (fuel moisture)")
  message("  Different variables can show different fire risk patterns")
  message("  High VPD doesn't always mean low FM1000 (and vice versa)")
} else {
  message("Middle Rockies forecast not found for comparison")
}

message("")
message("========================================")
message("Conclusion")
message("========================================")
message("")

message("To validate if zero fire danger is correct, check:")
message("1. Are FM1000 values HIGH (>50-60)? → Wet fuels → Low fire risk ✓")
message("2. Are FM1000INV percentiles LOW (<50th)? → Below median dryness ✓")
message("3. Does the eCDF map low percentiles to low fire danger? ✓")
message("")
message("If all three are true, zero fire danger is CORRECT.")
message("If FM1000 is low (dry fuels) but fire danger is zero, there's a bug.")
message("")
