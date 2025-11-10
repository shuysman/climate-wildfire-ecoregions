#!/usr/bin/env Rscript
## Check if we're comparing the correct time layers between ensemble and daily files
##
## The ensemble files are "_0.nc" meaning "day 0" forecast
## But we need to verify:
## 1. What does layer 1 represent in each file?
## 2. Are the time axes aligned?
## 3. Are we comparing apples-to-apples?

library(terra)
library(ncdf4)
library(tidyverse)
library(glue)

message("========================================")
message("VPD Time Alignment Check")
message("========================================")
message("")

# Files to compare
ensemble_mean_file <- "data/forecasts/vpd_test/vpd_ensemble_mean.nc"
daily_file <- "data/forecasts/vpd_test/cfsv2_metdata_forecast_vpd_daily.nc"
example_ensemble_member <- "data/forecasts/vpd_test/cfsv2_metdata_forecast_vpd_daily_00_1_0.nc"

message("Checking NetCDF metadata with ncdf4...")
message("")

# Function to extract time info from NetCDF
check_time_info <- function(filepath, label) {
  message(glue("--- {label} ---"))
  message(glue("File: {basename(filepath)}"))

  nc <- nc_open(filepath)

  # Get dimensions
  message("Dimensions:")
  for (dim_name in names(nc$dim)) {
    dim_obj <- nc$dim[[dim_name]]
    message(glue("  {dim_name}: {dim_obj$len} values"))
  }

  # Look for time variable
  message("")
  message("Variables:")
  for (var_name in names(nc$var)) {
    var_obj <- nc$var[[var_name]]
    message(glue("  {var_name}: {paste(var_obj$dim, collapse=' x ')}"))
  }

  # Try to extract time information
  message("")
  if ("day" %in% names(nc$dim)) {
    day_vals <- ncvar_get(nc, "day")
    message(glue("Day values (first 10): {paste(head(day_vals, 10), collapse=', ')}"))
    message(glue("Day range: {min(day_vals)} to {max(day_vals)}"))
  }

  if ("time" %in% names(nc$dim)) {
    time_vals <- ncvar_get(nc, "time")
    message(glue("Time values (first 10): {paste(head(time_vals, 10), collapse=', ')}"))

    # Try to parse time units
    time_var <- nc$dim$time
    if (!is.null(time_var$units)) {
      message(glue("Time units: {time_var$units}"))

      # Try to convert to dates
      if (grepl("days since", time_var$units)) {
        origin_str <- sub("days since ", "", time_var$units)
        origin <- as.Date(origin_str)
        dates <- origin + time_vals
        message(glue("Interpreted dates (first 10): {paste(head(dates, 10), collapse=', ')}"))
        message(glue("Date range: {min(dates)} to {max(dates)}"))
      }
    }
  }

  nc_close(nc)
  message("")
}

# Check each file
check_time_info(example_ensemble_member, "Example Ensemble Member (00_1_0)")
check_time_info(ensemble_mean_file, "Ensemble Mean (our computation)")
check_time_info(daily_file, "Daily Aggregated File (Katherine's)")

message("========================================")
message("Layer-by-Layer Comparison (terra)")
message("========================================")
message("")

# Load with terra and check what it sees
ens_rast <- rast(ensemble_mean_file)
daily_rast <- rast(daily_file)

message("Terra interpretation:")
message(glue("Ensemble mean: {nlyr(ens_rast)} layers"))
message(glue("Daily file: {nlyr(daily_rast)} layers"))
message("")

# Check time() function
message("Time metadata from terra:")
ens_time <- time(ens_rast)
daily_time <- time(daily_rast)

message("Ensemble mean times:")
if (!is.null(ens_time) && any(!is.na(ens_time))) {
  message(glue("  First 10: {paste(head(ens_time, 10), collapse=', ')}"))
} else {
  message("  No time metadata or all NA")
}

message("Daily file times:")
if (!is.null(daily_time) && any(!is.na(daily_time))) {
  message(glue("  First 10: {paste(head(daily_time, 10), collapse=', ')}"))
} else {
  message("  No time metadata or all NA")
}

message("")
message("========================================")
message("Manual Date Calculation")
message("========================================")
message("")

# Today's date
today <- Sys.Date()
message(glue("Today's date: {today}"))
message("")

# For ensemble files ending in "_0.nc", day 0 should be TODAY's forecast
# Let's verify by checking the file creation/modification time
ensemble_file_info <- file.info(example_ensemble_member)
message(glue("Ensemble file modified: {ensemble_file_info$mtime}"))

daily_file_info <- file.info(daily_file)
message(glue("Daily file modified: {daily_file_info$mtime}"))
message("")

message("Expected layer meanings:")
message("  Ensemble _0.nc files: Layer 1 = today's forecast, Layer 2 = tomorrow, etc.")
message("  Daily file: Layer 1 = ??? (need to verify)")
message("")

message("========================================")
message("Comparing Layer Values to Infer Dates")
message("========================================")
message("")

# Compare global means of first several layers
n_layers <- min(10, nlyr(ens_rast), nlyr(daily_rast))

comparison <- tibble(
  layer = 1:n_layers,
  ensemble_mean = numeric(n_layers),
  daily_mean = numeric(n_layers),
  difference = numeric(n_layers)
)

for (i in 1:n_layers) {
  ens_vals <- values(ens_rast[[i]], na.rm = TRUE)
  daily_vals <- values(daily_rast[[i]], na.rm = TRUE)

  comparison$ensemble_mean[i] <- mean(ens_vals)
  comparison$daily_mean[i] <- mean(daily_vals)
  comparison$difference[i] <- comparison$ensemble_mean[i] - comparison$daily_mean[i]
}

print(comparison)

message("")
message("Analysis:")
# If layer 1 ensemble matches layer 2 daily, it means daily starts with "yesterday"
# If they match at layer 1, it means both start with "today"

# Find best match for ensemble layer 1
daily_means <- sapply(1:min(5, nlyr(daily_rast)), function(i) {
  mean(values(daily_rast[[i]], na.rm = TRUE))
})

ens_layer1_mean <- comparison$ensemble_mean[1]
daily_diffs <- abs(daily_means - ens_layer1_mean)
best_match <- which.min(daily_diffs)

message(glue("Ensemble layer 1 mean: {round(ens_layer1_mean, 6)} kPa"))
message("")
message("Daily file layer means:")
for (i in seq_along(daily_means)) {
  diff_val <- abs(daily_means[i] - ens_layer1_mean)
  marker <- if (i == best_match) " <-- BEST MATCH" else ""
  message(glue("  Layer {i}: {round(daily_means[i], 6)} kPa (diff: {round(diff_val, 6)}){marker}"))
}

message("")
message("========================================")
message("Conclusion")
message("========================================")
message("")

if (best_match == 1) {
  message("✓ Layer 1 of ensemble matches Layer 1 of daily file")
  message("  Both files start with TODAY's forecast")
  message("  Our comparison in the validation script is CORRECT")
} else {
  message("✗ Layer 1 of ensemble matches Layer {best_match} of daily file")
  message("  The files have DIFFERENT time offsets!")
  message("  The validation script is comparing WRONG dates!")
  message("")
  message("  FIX NEEDED:")
  message(glue("  - Ensemble layer 1 = Daily layer {best_match}"))
  message(glue("  - Ensemble layer 2 = Daily layer {best_match + 1}"))
  message("  - etc.")
}

message("")
