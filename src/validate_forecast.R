#!/usr/bin/env Rscript
# validate_forecast.R
#
# Purpose: Validate that today's fire danger forecast contains plausible values
# based on historical fire danger distributions. Runs as part of daily pipeline
# to catch errors before publishing forecasts.
#
# Usage: Rscript src/validate_forecast.R <ecoregion_name_clean>
#   Example: Rscript src/validate_forecast.R middle_rockies
#
# Validation checks:
# 1. Fire danger values are in [0, 1] range
# 2. Spatial coverage matches expected (no excessive NAs)
# 3. Distribution matches historical patterns (no all-zeros, no all-ones)
# 4. Reasonable spatial variation (not uniform across landscape)
#
# Exit codes:
#   0 = All validations passed
#   1 = Critical validation failure (forecast should not be published)
#   2 = Warning (forecast usable but investigate anomalies)

suppressPackageStartupMessages({
  library(terra)
  library(yaml)
  library(glue)
  library(dplyr)
})

# ============================================================================
# PARSE ARGUMENTS
# ============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("Usage: Rscript src/validate_forecast.R <ecoregion_name_clean>")
}

ecoregion_name_clean <- args[1]

# ============================================================================
# LOAD CONFIGURATION
# ============================================================================

message("========================================")
message(glue("Validating forecast for: {ecoregion_name_clean}"))
message("========================================")

config <- read_yaml("config/ecoregions.yaml")
ecoregion_config <- config$ecoregions[[which(sapply(config$ecoregions, function(x) x$name_clean == ecoregion_name_clean))]]

if (is.null(ecoregion_config)) {
  stop(glue("Ecoregion '{ecoregion_name_clean}' not found in config"))
}

ecoregion_name <- ecoregion_config$name
ecoregion_id <- ecoregion_config$id

# ============================================================================
# LOAD FORECAST DATA
# ============================================================================

today <- Sys.Date()
forecast_dir <- file.path("out/forecasts", ecoregion_name_clean, today)
forecast_file <- file.path(forecast_dir, "fire_danger_forecast.nc")

if (!file.exists(forecast_file)) {
  stop(glue("Forecast file not found: {forecast_file}"))
}

message(glue("Loading forecast from: {forecast_file}"))
forecast_rast <- rast(forecast_file)

# Get today's layer (first layer in the forecast)
today_layer <- subset(forecast_rast, 1)
forecast_values <- values(today_layer, na.rm = FALSE)

# ============================================================================
# VALIDATION CHECKS
# ============================================================================

validation_errors <- character(0)
validation_warnings <- character(0)

# --- Check 1: Value range [0, 1] ---
message("Check 1: Value range validation...")
values_valid <- forecast_values[!is.na(forecast_values)]

if (length(values_valid) == 0) {
  validation_errors <- c(validation_errors, "All forecast values are NA")
} else {
  min_val <- min(values_valid, na.rm = TRUE)
  max_val <- max(values_valid, na.rm = TRUE)

  if (min_val < 0 || max_val > 1) {
    validation_errors <- c(validation_errors,
      glue("Values outside [0,1] range: min={round(min_val, 4)}, max={round(max_val, 4)}"))
  } else {
    message(glue("  ✓ Value range: [{round(min_val, 3)}, {round(max_val, 3)}]"))
  }
}

# --- Check 2: Spatial coverage ---
message("Check 2: Spatial coverage validation...")
total_cells <- length(forecast_values)
na_cells <- sum(is.na(forecast_values))
valid_cells <- total_cells - na_cells
coverage_pct <- 100 * (1 - na_cells / total_cells)

# Note: Forecasts are masked to ecoregion boundaries, so we expect significant
# NA area. Check for complete failure (all NA or nearly all NA).
if (valid_cells == 0) {
  validation_errors <- c(validation_errors,
    "All forecast values are NA - complete spatial failure")
} else if (valid_cells < 1000) {
  validation_errors <- c(validation_errors,
    glue("Very few valid cells: only {valid_cells} cells have values"))
} else {
  message(glue("  ✓ Spatial coverage: {valid_cells} valid cells ({round(coverage_pct, 1)}% of raster)"))
}

# --- Check 3: Distribution plausibility ---
message("Check 3: Distribution plausibility...")

if (length(values_valid) > 0) {
  # Check for degenerate distributions
  unique_values <- length(unique(values_valid))

  if (unique_values == 1) {
    validation_errors <- c(validation_errors,
      glue("All values identical: {unique(values_valid)[1]}"))
  }

  # Check for suspicious concentrations
  zero_pct <- 100 * sum(values_valid == 0) / length(values_valid)
  one_pct <- 100 * sum(values_valid == 1) / length(values_valid)

  if (zero_pct > 95) {
    validation_errors <- c(validation_errors,
      glue("Nearly all zeros: {round(zero_pct, 1)}% of values are 0"))
  } else if (zero_pct > 80) {
    validation_warnings <- c(validation_warnings,
      glue("High zero concentration: {round(zero_pct, 1)}% of values are 0"))
  }

  if (one_pct > 95) {
    validation_errors <- c(validation_errors,
      glue("Nearly all ones: {round(one_pct, 1)}% of values are 1"))
  } else if (one_pct > 80) {
    validation_warnings <- c(validation_warnings,
      glue("High saturation: {round(one_pct, 1)}% of values are 1"))
  }

  # Distribution summary
  quartiles <- quantile(values_valid, probs = c(0.25, 0.5, 0.75))
  message(glue("  ✓ Distribution: Q1={round(quartiles[1], 3)}, Median={round(quartiles[2], 3)}, Q3={round(quartiles[3], 3)}"))
}

# --- Check 4: Spatial variation ---
message("Check 4: Spatial variation...")

if (length(values_valid) > 100) {  # Need enough cells for meaningful calculation
  # Calculate coefficient of variation
  mean_val <- mean(values_valid, na.rm = TRUE)
  sd_val <- sd(values_valid, na.rm = TRUE)

  if (mean_val > 0) {
    cv <- sd_val / mean_val

    # Expect some spatial variation (cv > 0.05 means at least 5% relative variation)
    if (cv < 0.01) {
      validation_warnings <- c(validation_warnings,
        glue("Very low spatial variation: CV={round(cv, 4)}"))
    } else {
      message(glue("  ✓ Spatial variation: CV={round(cv, 3)}"))
    }
  }
}

# --- Check 5: Compare to historical eCDF ---
message("Check 5: Historical consistency check...")

# Load eCDF to get historical fire danger distribution
ecdf_dir <- file.path("data/ecdf", glue("{ecoregion_id}-{ecoregion_name_clean}-forest"))
ecdf_file <- file.path(ecdf_dir, "ecdf.rds")

if (file.exists(ecdf_file)) {
  ecdf_data <- readRDS(ecdf_file)

  # The eCDF maps percentiles to fire occurrence proportions
  # Check if forecast distribution is reasonable compared to historical

  if ("percentile" %in% names(ecdf_data) && "fire_occurrence" %in% names(ecdf_data)) {
    # Get expected distribution from eCDF
    hist_median <- median(ecdf_data$fire_occurrence, na.rm = TRUE)
    hist_q75 <- quantile(ecdf_data$fire_occurrence, 0.75, na.rm = TRUE)

    # Compare to today's forecast
    forecast_median <- median(values_valid, na.rm = TRUE)
    forecast_q75 <- quantile(values_valid, 0.75, na.rm = TRUE)

    # Forecasts shouldn't be dramatically different from historical patterns
    # (though they can be higher/lower depending on current conditions)
    if (forecast_median > hist_q75 + 0.2) {
      validation_warnings <- c(validation_warnings,
        glue("Forecast median ({round(forecast_median, 3)}) unusually high compared to historical Q3 ({round(hist_q75, 3)})"))
    }

    message(glue("  ✓ Historical context: median={round(hist_median, 3)}, forecast median={round(forecast_median, 3)}"))
  }
} else {
  message("  ⚠ eCDF file not found, skipping historical comparison")
}

# ============================================================================
# REPORT RESULTS
# ============================================================================

message("========================================")
message("Validation Results:")
message("========================================")

has_errors <- length(validation_errors) > 0
has_warnings <- length(validation_warnings) > 0

if (has_errors) {
  message("❌ CRITICAL ERRORS:")
  for (err in validation_errors) {
    message(glue("  - {err}"))
  }
}

if (has_warnings) {
  message("⚠️  WARNINGS:")
  for (warn in validation_warnings) {
    message(glue("  - {warn}"))
  }
}

if (!has_errors && !has_warnings) {
  message("✓ All validation checks passed")
  message("========================================")
  quit(status = 0)
} else if (has_errors) {
  message("========================================")
  message("VALIDATION FAILED: Do not publish this forecast")
  message("========================================")
  quit(status = 1)
} else {
  message("========================================")
  message("VALIDATION WARNINGS: Forecast usable but investigate anomalies")
  message("========================================")
  quit(status = 2)
}
