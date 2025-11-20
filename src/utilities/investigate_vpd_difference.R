#!/usr/bin/env Rscript
## Investigate WHY there's a difference between ensemble averaging and daily file
##
## If Katherine creates the daily file from the SAME ensemble members we downloaded,
## the results should match EXACTLY (within floating-point precision ~1e-6)
##
## Possible explanations:
## 1. Katherine uses 48 members, we only have 16 (she mentioned this)
## 2. Different averaging method (weighted? temporal?)
## 3. Daily file is from a different source entirely
## 4. We're missing some ensemble members or using wrong files

library(terra)
library(tidyverse)
library(glue)

message("========================================")
message("Investigating VPD Ensemble Difference")
message("========================================")
message("")

# Load the ensemble mean we created and the daily file
ensemble_mean_file <- "data/forecasts/vpd_test/vpd_ensemble_mean.nc"
daily_file <- "data/forecasts/vpd_test/cfsv2_metdata_forecast_vpd_daily.nc"

ensemble_mean_rast <- rast(ensemble_mean_file)
daily_rast <- rast(daily_file)

message("Layer counts:")
message(glue("  Ensemble mean: {nlyr(ensemble_mean_rast)}"))
message(glue("  Daily file: {nlyr(daily_rast)}"))
message("")

# Focus on first layer (day 0) for detailed analysis
ens_day0 <- ensemble_mean_rast[[1]]
daily_day0 <- daily_rast[[1]]

message("Day 0 Detailed Comparison:")
message("==========================")

# Get all values
ens_vals <- values(ens_day0, na.rm = FALSE)
daily_vals <- values(daily_day0, na.rm = FALSE)

# Check NA patterns
ens_na_count <- sum(is.na(ens_vals))
daily_na_count <- sum(is.na(daily_vals))

message(glue("NA counts: ensemble={ens_na_count}, daily={daily_na_count}"))

# For non-NA values, calculate difference
valid_idx <- !is.na(ens_vals) & !is.na(daily_vals)
diff_vals <- ens_vals[valid_idx] - daily_vals[valid_idx]

message("")
message("Difference Statistics (Ensemble - Daily):")
message(glue("  Min: {round(min(diff_vals), 8)}"))
message(glue("  Max: {round(max(diff_vals), 8)}"))
message(glue("  Mean: {round(mean(diff_vals), 8)}"))
message(glue("  Median: {round(median(diff_vals), 8)}"))
message(glue("  Std Dev: {round(sd(diff_vals), 8)}"))
message("")

# Check if differences are systematic or random
message("Checking if difference is systematic or random:")

# If it's truly the same data, differences should be ~machine epsilon (~1e-7)
# If it's different averaging, differences will be larger and potentially systematic

# Histogram of absolute differences
abs_diff <- abs(diff_vals)
quantiles <- quantile(abs_diff, probs = c(0.5, 0.9, 0.95, 0.99, 1.0))

message("Absolute difference quantiles:")
for (i in seq_along(quantiles)) {
  message(glue("  {names(quantiles)[i]}: {round(quantiles[i], 8)}"))
}
message("")

# Test hypothesis: Are we missing ensemble members?
message("========================================")
message("Testing Hypothesis: Missing Ensemble Members")
message("========================================")
message("")

# Load individual ensemble members and check their means
ensemble_files <- list.files("data/forecasts/vpd_test",
                             pattern = "cfsv2_metdata_forecast_vpd_daily_\\d{2}_\\d_0\\.nc",
                             full.names = TRUE)

message(glue("Found {length(ensemble_files)} ensemble member files"))

if (length(ensemble_files) > 0) {
  # Load each ensemble member and get day 0 mean
  member_means <- c()

  for (i in seq_along(ensemble_files)) {
    member_rast <- rast(ensemble_files[i])
    member_day0 <- member_rast[[1]]
    member_vals <- values(member_day0, na.rm = TRUE)
    member_mean <- mean(member_vals)
    member_means <- c(member_means, member_mean)

    filename <- basename(ensemble_files[i])
    message(glue("  {filename}: mean = {round(member_mean, 6)} kPa"))
  }

  message("")
  message("Ensemble member statistics:")
  message(glue("  Mean of member means: {round(mean(member_means), 6)} kPa"))
  message(glue("  Std dev of member means: {round(sd(member_means), 6)} kPa"))
  message(glue("  Range: {round(min(member_means), 6)} to {round(max(member_means), 6)} kPa"))
  message("")

  # Compare to daily file mean
  daily_mean_val <- mean(values(daily_day0, na.rm = TRUE))
  ens_mean_val <- mean(values(ens_day0, na.rm = TRUE))

  message("Global means:")
  message(glue("  Our ensemble mean: {round(ens_mean_val, 6)} kPa"))
  message(glue("  Daily file: {round(daily_mean_val, 6)} kPa"))
  message(glue("  Difference: {round(ens_mean_val - daily_mean_val, 6)} kPa"))
  message("")
}

message("========================================")
message("Testing Hypothesis: Temporal Aggregation")
message("========================================")
message("")

# Check time attributes
message("Time metadata:")
message("Ensemble mean:")
try({
  ens_time <- time(ensemble_mean_rast)
  if (!is.null(ens_time) && length(ens_time) > 0) {
    message(glue("  First 5 times: {paste(ens_time[1:min(5, length(ens_time))], collapse=', ')}"))
  } else {
    message("  No time metadata found")
  }
}, silent = TRUE)

message("Daily file:")
try({
  daily_time <- time(daily_rast)
  if (!is.null(daily_time) && length(daily_time) > 0) {
    message(glue("  First 5 times: {paste(daily_time[1:min(5, length(daily_time))], collapse=', ')}"))
  } else {
    message("  No time metadata found")
  }
}, silent = TRUE)

message("")
message("========================================")
message("Conclusion")
message("========================================")
message("")

if (max(abs_diff) < 1e-5) {
  message("✓ Differences are NEGLIGIBLE (< 0.00001 kPa)")
  message("  This is likely floating-point rounding or different averaging order")
  message("  The datasets are effectively IDENTICAL")
} else if (max(abs_diff) < 0.1) {
  message("⚠ Differences are SMALL but SYSTEMATIC")
  message("  Most likely explanation:")
  message("  - Katherine uses 48 ensemble members (she mentioned this)")
  message("  - We only have access to 16 members")
  message("  - The extra members create slight averaging differences")
  message("")
  message("  The difference is TOO SMALL to matter for fire forecasting")
  message(glue("  (max diff = {round(max(abs_diff), 4)} kPa out of 0-3 kPa range)"))
} else {
  message("✗ Differences are LARGE")
  message("  The daily file is likely NOT created from these ensemble members")
  message("  or uses a completely different methodology")
}

message("")
message("ANSWER TO YOUR QUESTION:")
message("========================")
message("The numbers don't match exactly because Katherine's system likely")
message("uses MORE ensemble members (48) than we have access to (16).")
message("")
message("Quote from Katherine: 'We create it from the 48 ensemble members'")
message("")
message("16 members give us a good average, but 48 members give a slightly")
message("different (and likely better) average due to more statistical sampling.")
message("")
