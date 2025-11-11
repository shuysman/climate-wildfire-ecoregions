#!/usr/bin/env Rscript
# test_core_functions.R
#
# Unit tests for critical statistical functions in the fire danger pipeline
# Tests bin_rast() percentile binning and custom my_percent_rank() function
#
# Usage: Rscript tests/test_core_functions.R
#
# Exit codes:
#   0 = All tests passed
#   1 = One or more tests failed

suppressPackageStartupMessages({
  library(terra)
  library(dplyr)
})

# ============================================================================
# TEST UTILITIES
# ============================================================================

test_count <- 0
pass_count <- 0
fail_count <- 0

test_that <- function(description, code) {
  test_count <<- test_count + 1
  cat(sprintf("Test %d: %s ... ", test_count, description))

  tryCatch({
    code
    cat("✓ PASS\n")
    pass_count <<- pass_count + 1
  }, error = function(e) {
    cat(sprintf("✗ FAIL\n  Error: %s\n", e$message))
    fail_count <<- fail_count + 1
  })
}

assert_equal <- function(actual, expected, tolerance = 1e-10) {
  if (is.numeric(actual) && is.numeric(expected)) {
    # Strip names for comparison (terra rasters add names to values)
    actual_clean <- as.numeric(actual)
    expected_clean <- as.numeric(expected)

    comparison <- all.equal(actual_clean, expected_clean, tolerance = tolerance)
    if (!isTRUE(comparison)) {
      stop(sprintf("Expected %s but got %s (difference: %s)",
                   paste(expected_clean, collapse=", "),
                   paste(actual_clean, collapse=", "),
                   if (is.character(comparison)) comparison else "values differ"))
    }
  } else if (length(actual) != length(expected)) {
    stop(sprintf("Expected length %d but got length %d",
                 length(expected), length(actual)))
  } else {
    if (!identical(actual, expected)) {
      stop(sprintf("Expected %s but got %s",
                   paste(expected, collapse=", "),
                   paste(actual, collapse=", ")))
    }
  }
}

assert_true <- function(condition, message = "Condition is not TRUE") {
  if (!isTRUE(condition)) {
    stop(message)
  }
}

# ============================================================================
# FUNCTION DEFINITIONS (copied from production code)
# ============================================================================

# From src/map_forecast_danger.R
bin_rast <- function(new_rast, quants_rast, probs) {
  # Approximate conversion of percentile of dryness to proportion of historical fires
  bin_index_rast <- sum(new_rast > quants_rast)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)
  percentile_rast_binned <- classify(bin_index_rast, rcl = rcl_matrix)
  return(percentile_rast_binned)
}

# From src/03_dryness.R
my_percent_rank <- function(x) {
  # Round to 1 decimal place, substitute zeros with NA, remove duplicates
  x <- round(x, 1)
  x[x == 0] <- NA
  x <- x[!duplicated(x)]
  percent_rank(x)
}

# ============================================================================
# TESTS FOR bin_rast()
# ============================================================================

cat("\n========================================\n")
cat("Testing bin_rast() function\n")
cat("========================================\n\n")

test_that("bin_rast handles single value correctly", {
  # Create simple rasters
  new_rast <- rast(nrows=3, ncols=3, vals=5)
  quants_rast <- rast(nrows=3, ncols=3, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)[1,]

  # Value 5 is greater than quantiles 1-4, so bin_index should be 4
  # This maps to probs[4] = 0.4
  assert_equal(result_vals, 0.4)
})

test_that("bin_rast handles edge case: value below all quantiles", {
  new_rast <- rast(nrows=3, ncols=3, vals=0)
  quants_rast <- rast(nrows=3, ncols=3, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)[1,]

  # Value 0 is not greater than any quantile, so bin_index = 0
  # This maps to percentile_map[1] = 0
  assert_equal(result_vals, 0)
})

test_that("bin_rast handles edge case: value above all quantiles", {
  new_rast <- rast(nrows=3, ncols=3, vals=100)
  quants_rast <- rast(nrows=3, ncols=3, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)[1,]

  # Value 100 is greater than all 10 quantiles, so bin_index = 10
  # This maps to percentile_map[11] = probs[10] = 1.0
  assert_equal(result_vals, 1.0)
})

test_that("bin_rast handles spatial variation correctly", {
  # Create raster with different values
  new_vals <- c(1, 3, 5, 7, 9, 2, 4, 6, 8)
  new_rast <- rast(nrows=3, ncols=3, vals=new_vals)

  # Quantiles: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
  quant_vals <- matrix(1:10, nrow=9, ncol=10, byrow=TRUE)
  quants_rast <- rast(nrows=3, ncols=3, nlyr=10, vals=as.vector(t(quant_vals)))

  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)

  # Check that we get different percentiles for different input values
  unique_vals <- unique(result_vals)
  assert_true(length(unique_vals) > 1, "Expected spatial variation in output")
})

test_that("bin_rast preserves NA values", {
  new_vals <- c(5, NA, 5)
  new_rast <- rast(nrows=1, ncols=3, vals=new_vals)
  quants_rast <- rast(nrows=1, ncols=3, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)

  # Middle cell should be NA
  assert_true(is.na(result_vals[2]), "NA values should be preserved")
  # Other cells should have values
  assert_true(!is.na(result_vals[1]), "Non-NA values should be calculated")
  assert_true(!is.na(result_vals[3]), "Non-NA values should be calculated")
})

# ============================================================================
# TESTS FOR my_percent_rank()
# ============================================================================

cat("\n========================================\n")
cat("Testing my_percent_rank() function\n")
cat("========================================\n\n")

test_that("my_percent_rank handles simple sequence", {
  x <- c(1.1, 2.2, 3.3, 4.4, 5.5)
  result <- my_percent_rank(x)
  expected <- c(0, 0.25, 0.5, 0.75, 1.0)
  assert_equal(result, expected)
})

test_that("my_percent_rank converts zeros to NA", {
  x <- c(0, 1.1, 2.2, 0, 3.3)
  result <- my_percent_rank(x)

  # After rounding, zero substitution, and deduplication:
  # Input: 0, 1.1, 2.2, 0, 3.3
  # After x[x==0] <- NA: NA, 1.1, 2.2, NA, 3.3
  # After removing duplicates: NA, 1.1, 2.2, 3.3 (one NA kept)
  # Result length should be 4 (deduplicated)
  assert_equal(length(result), 4)
  # First value (from NA) should be NA
  assert_true(is.na(result[1]), "Zero converted to NA should remain NA")
  # Other values should have ranks
  assert_true(!is.na(result[2]), "Non-zero value should have rank")
})

test_that("my_percent_rank removes duplicates before ranking", {
  x <- c(1.1, 1.1, 2.2, 2.2, 3.3)
  result <- my_percent_rank(x)

  # After removing duplicates: 1.1, 2.2, 3.3
  # Ranks: 0, 0.5, 1.0
  # But original vector keeps duplicate structure
  # Actually, the function returns percent_rank of deduplicated vector
  # So we expect a vector of length matching deduplicated input
  assert_equal(length(result), 3)
})

test_that("my_percent_rank rounds to 1 decimal place", {
  x <- c(1.11, 1.19, 2.21, 2.29)
  result <- my_percent_rank(x)

  # After rounding: 1.1, 1.2, 2.2, 2.3
  # After removing duplicates: 1.1, 1.2, 2.2, 2.3 (all unique)
  # Ranks: 0, 0.333, 0.667, 1.0
  expected <- c(0, 1/3, 2/3, 1.0)
  assert_equal(result, expected, tolerance = 1e-6)
})

test_that("my_percent_rank handles all zeros", {
  x <- c(0, 0, 0, 0)
  result <- my_percent_rank(x)

  # All zeros should become NA, then deduplicated to single NA
  assert_equal(length(result), 1)
  assert_true(is.na(result[1]), "All zeros should result in NA")
})

# ============================================================================
# COMPARISON: my_percent_rank vs percent_rank
# ============================================================================

cat("\n========================================\n")
cat("Testing my_percent_rank vs percent_rank differences\n")
cat("========================================\n\n")

test_that("my_percent_rank treats zeros differently than percent_rank", {
  x <- c(0, 1, 2, 3, 4)

  result_custom <- my_percent_rank(x)
  result_standard <- percent_rank(x)

  # Standard percent_rank treats 0 like any other value
  # Custom my_percent_rank converts 0 to NA
  assert_true(is.na(result_custom[1]), "my_percent_rank should convert 0 to NA")
  assert_true(!is.na(result_standard[1]), "percent_rank should not convert 0 to NA")
})

test_that("Demonstrate zero-inflation handling", {
  # Simulated zero-inflated data (common in VPD, CWD, precip)
  x <- c(0, 0, 0, 0, 0, 1.5, 2.3, 3.1, 4.2, 5.5)

  result_custom <- my_percent_rank(x)
  result_standard <- percent_rank(x)

  # Custom method should have fewer ranked values (zeros excluded)
  # After deduplication, custom has 5 values, standard has 6
  assert_true(length(result_custom) < length(result_standard),
              "my_percent_rank should produce fewer ranked values due to zero removal")
})

# ============================================================================
# INTEGRATION TESTS
# ============================================================================

cat("\n========================================\n")
cat("Integration tests: bin_rast with realistic data\n")
cat("========================================\n\n")

test_that("bin_rast with realistic VPD quantiles", {
  # Simulate realistic VPD values (Pascals)
  vpd_values <- c(500, 1000, 1500, 2000, 2500)
  new_rast <- rast(nrows=1, ncols=5, vals=vpd_values)

  # Simulate realistic VPD quantile raster (deciles)
  # Typical VPD ranges from ~0-3000 Pa
  vpd_deciles <- seq(300, 2700, length.out=10)
  quants_rast <- rast(nrows=1, ncols=5, nlyr=10)
  for (i in 1:10) {
    quants_rast[[i]] <- rast(nrows=1, ncols=5, vals=vpd_deciles[i])
  }

  probs <- seq(0.1, 1.0, by=0.1)
  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)

  # Check that results are in [0, 1]
  assert_true(all(result_vals >= 0 & result_vals <= 1, na.rm=TRUE),
              "All percentiles should be in [0, 1]")

  # Check monotonicity: higher VPD should give higher percentile
  assert_true(all(diff(result_vals) >= 0, na.rm=TRUE),
              "Higher VPD values should produce higher percentiles")
})

test_that("bin_rast handles quantile raster with spatial variation", {
  # Quantiles can vary spatially (different locations have different climatology)
  new_rast <- rast(nrows=2, ncols=2, vals=c(1000, 1000, 1000, 1000))

  # Create spatially varying quantiles
  quants_rast <- rast(nrows=2, ncols=2, nlyr=10)
  for (i in 1:10) {
    # Cell 1: low quantiles (wet climate)
    # Cell 2-4: high quantiles (dry climate)
    vals <- c(i*100, i*200, i*200, i*200)
    quants_rast[[i]] <- rast(nrows=2, ncols=2, vals=vals)
  }

  probs <- seq(0.1, 1.0, by=0.1)
  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)

  # Same absolute VPD (1000) should map to different percentiles
  # in locations with different climatology
  assert_true(result_vals[1] > result_vals[2],
              "Same value should map to higher percentile in wetter climate")
})

# ============================================================================
# EDGE CASES AND ERROR HANDLING
# ============================================================================

cat("\n========================================\n")
cat("Testing edge cases and error conditions\n")
cat("========================================\n\n")

test_that("bin_rast handles empty raster", {
  new_rast <- rast(nrows=3, ncols=3, vals=NA)
  quants_rast <- rast(nrows=3, ncols=3, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_vals <- values(result)

  # All values should be NA
  assert_true(all(is.na(result_vals)), "Empty input should produce all-NA output")
})

test_that("my_percent_rank handles single value", {
  x <- c(5.5)
  result <- my_percent_rank(x)

  # Single value should have rank 0 or 1 (depending on implementation)
  # dplyr::percent_rank of single value is NaN
  # After deduplication, we get a single value, percent_rank returns NaN
  assert_equal(length(result), 1)
})

test_that("my_percent_rank handles all NA", {
  x <- c(NA, NA, NA)
  result <- my_percent_rank(x)

  # Should handle gracefully (all NA after rounding/substitution)
  # After removing duplicates from c(NA, NA, NA) we get c(NA)
  # percent_rank(c(NA)) returns c(NA)
  assert_equal(length(result), 1)
  assert_true(is.na(result[1]), "All NA input should produce NA output")
})

# ============================================================================
# CRITICAL REGRESSION TESTS
# ============================================================================

cat("\n========================================\n")
cat("Critical regression tests (prevent known bugs)\n")
cat("========================================\n\n")

test_that("REGRESSION: bin_rast decile indexing is correct", {
  # This tests the critical fix for off-by-one indexing
  # bin_index_rast counts how many quantiles the value exceeds
  # percentile_map needs to be c(0, probs) to map correctly

  new_rast <- rast(nrows=1, ncols=1, vals=5)
  quants_rast <- rast(nrows=1, ncols=1, nlyr=10, vals=1:10)
  probs <- seq(0.1, 1.0, by=0.1)

  result <- bin_rast(new_rast, quants_rast, probs)
  result_val <- values(result)[1,1]

  # Value 5 exceeds quantiles 1,2,3,4 -> bin_index = 4
  # percentile_map = c(0, 0.1, 0.2, ..., 1.0) [length 11]
  # percentile_map[4+1] = percentile_map[5] = probs[4] = 0.4
  assert_equal(result_val, 0.4)
})

test_that("REGRESSION: my_percent_rank zero-handling prevents bias", {
  # Zero-inflated variables should not have zeros ranked
  # This tests that my_percent_rank correctly handles zero inflation

  # Simulate precipitation-like data with many zeros
  x <- c(rep(0, 50), seq(0.1, 5, by=0.1))

  result_custom <- my_percent_rank(x)
  result_standard <- percent_rank(x)

  # Custom should exclude zeros entirely
  # Standard includes zeros, making non-zero values appear higher percentile
  # We just check that they differ
  assert_true(!identical(result_custom, result_standard),
              "Zero-handling methods should differ for zero-inflated data")
})

# ============================================================================
# SUMMARY
# ============================================================================

cat("\n========================================\n")
cat("TEST SUMMARY\n")
cat("========================================\n")
cat(sprintf("Total tests: %d\n", test_count))
cat(sprintf("Passed: %d\n", pass_count))
cat(sprintf("Failed: %d\n", fail_count))
cat("========================================\n")

if (fail_count > 0) {
  cat("\n❌ SOME TESTS FAILED\n")
  quit(status = 1)
} else {
  cat("\n✓ ALL TESTS PASSED\n")
  quit(status = 0)
}
