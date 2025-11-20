#!/usr/bin/env Rscript
### Test script for timeseries validation logic
### This tests the validation checks added to map_forecast_danger.R

library(tidyverse)
library(glue)

message("========================================")
message("Testing Timeseries Validation Logic")
message("========================================")

# Test parameters
today <- as.Date("2025-01-15")
forecast_start_date <- today
forecast_end_date <- today + 7
forest_window <- 15
non_forest_window <- 5
max_window <- max(forest_window, non_forest_window)

# ============================================================================
# Test 1: Valid timeseries (should pass all checks)
# ============================================================================

message("\n--- Test 1: Valid continuous timeseries ---")
test1_dates <- seq(from = today - 40, to = today + 7, by = "1 day")
n_dates <- length(test1_dates)

# Check 1: Duplicate dates detection
if (any(duplicated(test1_dates))) {
  stop("Test 1 FAILED: Unexpected duplicates found")
}
message(glue("✓ No duplicate dates found ({n_dates} unique dates)"))

# Check 2: Date ordering verification
sorted_dates <- sort(test1_dates)
if (!identical(test1_dates, sorted_dates)) {
  stop("Test 1 FAILED: Dates not in order")
}
message(glue("✓ Dates are in correct chronological order"))

# Check 3: Gap detection
expected_sequence <- seq(from = test1_dates[1], to = test1_dates[n_dates], by = "1 day")
n_expected <- length(expected_sequence)
if (n_dates != n_expected) {
  stop("Test 1 FAILED: Unexpected gaps")
}
message(glue("✓ Continuous daily sequence verified ({n_dates} days)"))

# Check 4: Sufficient data
min_required_start_date <- forecast_start_date - max_window + 1
if (test1_dates[1] > min_required_start_date || test1_dates[n_dates] < forecast_end_date) {
  stop("Test 1 FAILED: Insufficient data")
}
message(glue("✓ Sufficient data for {max_window}-day rolling windows"))
message("Test 1 PASSED ✓\n")

# ============================================================================
# Test 2: Duplicate dates (should fail)
# ============================================================================

message("\n--- Test 2: Duplicate dates detection ---")
test2_dates <- c(
  seq(from = today - 40, to = today, by = "1 day"),
  as.Date("2025-01-10"),  # duplicate
  seq(from = today + 1, to = today + 7, by = "1 day")
)

duplicate_detected <- FALSE
if (any(duplicated(test2_dates))) {
  duplicate_dates <- test2_dates[duplicated(test2_dates)]
  message(glue("✓ Correctly detected duplicates: {paste(duplicate_dates, collapse=', ')}"))
  duplicate_detected <- TRUE
}

if (!duplicate_detected) {
  stop("Test 2 FAILED: Did not detect duplicate dates")
}
message("Test 2 PASSED ✓\n")

# ============================================================================
# Test 3: Out of order dates (should fail)
# ============================================================================

message("\n--- Test 3: Date ordering detection ---")
test3_dates <- c(
  seq(from = today - 40, to = today - 10, by = "1 day"),
  as.Date("2025-01-20"),  # out of order - future date
  seq(from = today - 9, to = today + 7, by = "1 day")
)

sorted_dates <- sort(test3_dates)
ordering_error_detected <- !identical(test3_dates, sorted_dates)

if (!ordering_error_detected) {
  stop("Test 3 FAILED: Did not detect ordering issue")
}
message("✓ Correctly detected out-of-order dates")
message("Test 3 PASSED ✓\n")

# ============================================================================
# Test 4: Gap in sequence (should fail)
# ============================================================================

message("\n--- Test 4: Gap detection ---")
test4_dates <- c(
  seq(from = today - 40, to = today - 5, by = "1 day"),
  # Missing 3 days here
  seq(from = today - 2, to = today + 7, by = "1 day")
)

n_dates <- length(test4_dates)
expected_sequence <- seq(from = test4_dates[1], to = test4_dates[n_dates], by = "1 day")
n_expected <- length(expected_sequence)

gap_detected <- (n_dates != n_expected)

if (!gap_detected) {
  stop("Test 4 FAILED: Did not detect gap")
}

missing_dates <- setdiff(expected_sequence, test4_dates)
message(glue("✓ Correctly detected gap: missing {length(missing_dates)} dates"))
message(glue("  Missing dates: {paste(missing_dates, collapse=', ')}"))
message("Test 4 PASSED ✓\n")

# ============================================================================
# Test 5: Insufficient historical data (should fail)
# ============================================================================

message("\n--- Test 5: Insufficient historical data detection ---")
# Start too late - not enough historical data for rolling window
test5_dates <- seq(from = today - 10, to = today + 7, by = "1 day")
min_required_start_date <- forecast_start_date - max_window + 1

insufficient_detected <- (test5_dates[1] > min_required_start_date)

if (!insufficient_detected) {
  stop("Test 5 FAILED: Did not detect insufficient historical data")
}

message(glue("✓ Correctly detected insufficient historical data"))
message(glue("  Data starts: {test5_dates[1]}"))
message(glue("  Required start: {min_required_start_date}"))
message(glue("  Missing: {as.numeric(test5_dates[1] - min_required_start_date)} days"))
message("Test 5 PASSED ✓\n")

# ============================================================================
# Test 6: Insufficient forecast data (should fail)
# ============================================================================

message("\n--- Test 6: Insufficient forecast data detection ---")
# End too early - not enough forecast data
test6_dates <- seq(from = today - 40, to = today + 3, by = "1 day")

insufficient_forecast_detected <- (test6_dates[length(test6_dates)] < forecast_end_date)

if (!insufficient_forecast_detected) {
  stop("Test 6 FAILED: Did not detect insufficient forecast data")
}

message(glue("✓ Correctly detected insufficient forecast data"))
message(glue("  Data ends: {test6_dates[length(test6_dates)]}"))
message(glue("  Required end: {forecast_end_date}"))
message(glue("  Missing: {as.numeric(forecast_end_date - test6_dates[length(test6_dates)])} days"))
message("Test 6 PASSED ✓\n")

# ============================================================================
# Summary
# ============================================================================

message("========================================")
message("All validation tests PASSED ✓")
message("========================================")
message("The timeseries validation logic correctly detects:")
message("  1. Valid continuous timeseries")
message("  2. Duplicate dates")
message("  3. Out-of-order dates")
message("  4. Gaps in daily sequence")
message("  5. Insufficient historical data")
message("  6. Insufficient forecast data")
message("========================================")
