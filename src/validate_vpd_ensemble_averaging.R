#!/usr/bin/env Rscript
## Validate VPD Ensemble Averaging
##
## This script tests Katherine Hegewisch's assertion that we can reconstruct
## daily mean VPD by averaging ensemble members for VPD forecasts.
##
## Email context (Sep 10, 2025):
## Katherine: "We create it from the 48 ensemble members we have for each
## future forecast day. You can create it from the ensemble members that you
## have, i.e. 16 or 32"
##
## Test approach:
## 1. Download VPD ensemble files (16 members: 4 hours × 4 ensemble members)
## 2. Compute ensemble mean using NCO (same method as FM1000)
## 3. Compare to aggregated daily VPD file (cfsv2_metdata_forecast_vpd_daily.nc)
## 4. Calculate differences and assess if averaging is appropriate

library(terra)
library(tidyverse)
library(glue)

message("========================================")
message("VPD Ensemble Averaging Validation")
message("========================================")

# Configuration
BASE_URL <- "http://thredds.northwestknowledge.net:8080/thredds/fileServer/NWCSC_INTEGRATED_SCENARIOS_ALL_CLIMATE/cfsv2_metdata_90day"
TEST_DIR <- "data/forecasts/vpd_test"
dir.create(TEST_DIR, showWarnings = FALSE, recursive = TRUE)

# Ensemble structure
hours <- c("00", "06", "12", "18")
members <- c("1", "2", "3", "4")
test_day <- 0  # Today's forecast

message("Step 1: Downloading VPD ensemble members for day 0...")
message(glue("This will download 16 files (4 hours × 4 members)"))

ensemble_files <- c()
download_count <- 0

for (hour in hours) {
  for (member in members) {
    filename <- glue("cfsv2_metdata_forecast_vpd_daily_{hour}_{member}_{test_day}.nc")
    local_file <- file.path(TEST_DIR, filename)
    remote_url <- glue("{BASE_URL}/{filename}")

    message(glue("  Downloading {hour}_{member}_{test_day}..."))

    result <- tryCatch({
      download.file(remote_url, local_file, quiet = TRUE, mode = "wb")
      ensemble_files <- c(ensemble_files, local_file)
      download_count <- download_count + 1
      TRUE
    }, error = function(e) {
      message(glue("    WARNING: Failed to download {filename}"))
      message(glue("    Error: {e$message}"))
      FALSE
    })
  }
}

message(glue("Downloaded {download_count} of 16 ensemble members"))

if (download_count == 0) {
  stop("ERROR: No ensemble files could be downloaded. Check URL and network connection.")
}

if (download_count < 16) {
  message(glue("WARNING: Only {download_count} of 16 members downloaded. Results may not be representative."))
}

message("")
message("Step 2: Computing ensemble mean using NCO...")

# Check if NCO is available
if (system("command -v ncea", ignore.stdout = TRUE, ignore.stderr = TRUE) != 0) {
  stop("ERROR: NCO tools (ncea) not found. Install with: apt-get install nco")
}

ensemble_mean_file <- file.path(TEST_DIR, "vpd_ensemble_mean.nc")
ncea_cmd <- glue("ncea -O {paste(ensemble_files, collapse = ' ')} {ensemble_mean_file}")

system(ncea_cmd)

if (!file.exists(ensemble_mean_file)) {
  stop("ERROR: Failed to create ensemble mean file")
}

message("✓ Ensemble mean created successfully")

message("")
message("Step 3: Downloading aggregated daily VPD file...")

daily_file <- file.path(TEST_DIR, "cfsv2_metdata_forecast_vpd_daily.nc")
daily_url <- glue("{BASE_URL}/cfsv2_metdata_forecast_vpd_daily.nc")

tryCatch({
  download.file(daily_url, daily_file, quiet = TRUE, mode = "wb")
  message("✓ Daily aggregated file downloaded")
}, error = function(e) {
  stop(glue("ERROR: Failed to download daily file: {e$message}"))
})

message("")
message("Step 4: Loading rasters for comparison...")

ensemble_mean_rast <- rast(ensemble_mean_file)
daily_rast <- rast(daily_file)

message(glue("Ensemble mean layers: {nlyr(ensemble_mean_rast)}"))
message(glue("Daily aggregated layers: {nlyr(daily_rast)}"))

# Check if dimensions match
if (nlyr(ensemble_mean_rast) != nlyr(daily_rast)) {
  warning(glue("Layer count mismatch: ensemble={nlyr(ensemble_mean_rast)}, daily={nlyr(daily_rast)}"))
}

# Compare first few layers (forecast days)
n_layers_to_compare <- min(8, nlyr(ensemble_mean_rast), nlyr(daily_rast))

message("")
message(glue("Step 5: Comparing first {n_layers_to_compare} forecast days..."))
message("")

results <- tibble(
  day = integer(),
  ensemble_min = numeric(),
  ensemble_max = numeric(),
  ensemble_mean = numeric(),
  daily_min = numeric(),
  daily_max = numeric(),
  daily_mean = numeric(),
  diff_min = numeric(),
  diff_max = numeric(),
  diff_mean = numeric(),
  diff_rmse = numeric(),
  correlation = numeric()
)

for (i in 1:n_layers_to_compare) {
  ens_layer <- ensemble_mean_rast[[i]]
  daily_layer <- daily_rast[[i]]

  # Ensure same extent and resolution
  if (!compareGeom(ens_layer, daily_layer, stopOnError = FALSE)) {
    message(glue("  WARNING: Layer {i} has different geometry. Attempting to align..."))
    ens_layer <- resample(ens_layer, daily_layer)
  }

  # Calculate difference
  diff <- ens_layer - daily_layer

  # Extract statistics
  ens_vals <- values(ens_layer, na.rm = TRUE)
  daily_vals <- values(daily_layer, na.rm = TRUE)
  diff_vals <- values(diff, na.rm = TRUE)

  # Calculate correlation
  valid_idx <- !is.na(ens_vals) & !is.na(daily_vals)
  corr <- cor(ens_vals[valid_idx], daily_vals[valid_idx], use = "complete.obs")

  # Calculate RMSE
  rmse <- sqrt(mean(diff_vals^2, na.rm = TRUE))

  results <- results %>%
    add_row(
      day = i - 1,  # 0-indexed (day 0 = today)
      ensemble_min = min(ens_vals, na.rm = TRUE),
      ensemble_max = max(ens_vals, na.rm = TRUE),
      ensemble_mean = mean(ens_vals, na.rm = TRUE),
      daily_min = min(daily_vals, na.rm = TRUE),
      daily_max = max(daily_vals, na.rm = TRUE),
      daily_mean = mean(daily_vals, na.rm = TRUE),
      diff_min = min(diff_vals, na.rm = TRUE),
      diff_max = max(diff_vals, na.rm = TRUE),
      diff_mean = mean(diff_vals, na.rm = TRUE),
      diff_rmse = rmse,
      correlation = corr
    )

  message(glue("Day {i-1}: RMSE={round(rmse, 4)} Pa, Correlation={round(corr, 5)}, Mean diff={round(mean(diff_vals, na.rm=TRUE), 4)} Pa"))
}

message("")
message("========================================")
message("Summary Statistics")
message("========================================")

print(results %>%
  summarise(
    avg_rmse = mean(diff_rmse),
    max_rmse = max(diff_rmse),
    avg_correlation = mean(correlation),
    min_correlation = min(correlation),
    avg_mean_diff = mean(diff_mean),
    max_abs_mean_diff = max(abs(diff_mean))
  ))

message("")
message("========================================")
message("Detailed Results by Day")
message("========================================")
print(results)

# Save results
results_file <- file.path(TEST_DIR, "validation_results.csv")
write_csv(results, results_file)
message("")
message(glue("Results saved to: {results_file}"))

# Create comparison plot
message("")
message("Creating comparison plot...")

png(file.path(TEST_DIR, "vpd_ensemble_comparison.png"), width = 1200, height = 800)
par(mfrow = c(2, 2))

# Plot 1: Mean values comparison
plot(results$day, results$ensemble_mean, type = "b", col = "blue", pch = 16,
     xlab = "Forecast Day", ylab = "Mean VPD (Pa)",
     main = "Mean VPD: Ensemble vs Daily Aggregated")
lines(results$day, results$daily_mean, type = "b", col = "red", pch = 16)
legend("topright", legend = c("Ensemble Mean (16 members)", "Daily Aggregated"),
       col = c("blue", "red"), lty = 1, pch = 16)

# Plot 2: RMSE by day
plot(results$day, results$diff_rmse, type = "b", col = "darkgreen", pch = 16,
     xlab = "Forecast Day", ylab = "RMSE (Pa)",
     main = "Root Mean Square Error by Forecast Day")
abline(h = mean(results$diff_rmse), col = "red", lty = 2)
text(max(results$day), mean(results$diff_rmse),
     paste("Avg RMSE:", round(mean(results$diff_rmse), 2)), pos = 1)

# Plot 3: Correlation by day
plot(results$day, results$correlation, type = "b", col = "purple", pch = 16,
     xlab = "Forecast Day", ylab = "Correlation",
     main = "Spatial Correlation by Forecast Day", ylim = c(0.95, 1))
abline(h = mean(results$correlation), col = "red", lty = 2)

# Plot 4: Mean difference by day
plot(results$day, results$diff_mean, type = "b", col = "orange", pch = 16,
     xlab = "Forecast Day", ylab = "Mean Difference (Pa)",
     main = "Mean Difference (Ensemble - Daily)")
abline(h = 0, col = "red", lty = 2)

dev.off()

message("✓ Plot saved to: data/forecasts/vpd_test/vpd_ensemble_comparison.png")

message("")
message("========================================")
message("Conclusion")
message("========================================")

avg_rmse <- mean(results$diff_rmse)
avg_corr <- mean(results$correlation)
avg_diff <- mean(abs(results$diff_mean))

if (avg_corr > 0.999 && avg_rmse < 10) {
  message("✓ VALIDATION PASSED: Ensemble averaging produces nearly identical results to daily aggregated file")
  message(glue("  - Average correlation: {round(avg_corr, 6)} (>0.999)"))
  message(glue("  - Average RMSE: {round(avg_rmse, 2)} Pa (<10 Pa)"))
  message("  - Recommendation: Safe to use ensemble averaging for VPD")
} else if (avg_corr > 0.99 && avg_rmse < 50) {
  message("⚠ VALIDATION ACCEPTABLE: Ensemble averaging is similar but not identical")
  message(glue("  - Average correlation: {round(avg_corr, 6)}"))
  message(glue("  - Average RMSE: {round(avg_rmse, 2)} Pa"))
  message("  - Recommendation: Use with caution, monitor differences")
} else {
  message("✗ VALIDATION FAILED: Ensemble averaging differs significantly from daily aggregated file")
  message(glue("  - Average correlation: {round(avg_corr, 6)} (<0.99)"))
  message(glue("  - Average RMSE: {round(avg_rmse, 2)} Pa (>50 Pa)"))
  message("  - Recommendation: Do NOT use ensemble averaging for VPD")
}

message("")
message("Note: This validates Katherine's approach of averaging 16 ensemble members")
message("      (4 forecast hours × 4 ensemble members per hour)")
message("      Katherine's system uses 48 members (likely 4 hours × 12 members)")
message("")
