#!/usr/bin/env Rscript
# Test gridMET data availability via direct OPeNDAP access
# Bypasses climateR to diagnose availability issues
# Checks all variables used by the forecast system

library(ncdf4)
library(lubridate)

# Variables used by the forecast system and their OPeNDAP aggregate file names
variables <- list(
  vpd   = "agg_met_vpd_1979_CurrentYear_CONUS.nc",
  fm1000 = "agg_met_fm1000_1979_CurrentYear_CONUS.nc",
  tmmx  = "agg_met_tmmx_1979_CurrentYear_CONUS.nc",
  tmmn  = "agg_met_tmmn_1979_CurrentYear_CONUS.nc"
)

base_url <- "http://thredds.northwestknowledge.net:8080/thredds/dodsC"
today <- today()

cat("gridMET Data Availability Check\n")
cat("=================================================\n")
cat("Today's date:", as.character(today), "\n")
cat("Requested end date (today - 2):", as.character(today - 2), "\n\n")

summary_results <- list()

for (var_name in names(variables)) {
  opendap_url <- paste0(base_url, "/", variables[[var_name]])

  cat("-------------------------------------------------\n")
  cat("Variable:", toupper(var_name), "\n")
  cat("URL:", opendap_url, "\n")

  nc <- tryCatch({
    nc_open(opendap_url)
  }, error = function(e) {
    cat("  ERROR: Failed to connect -", e$message, "\n\n")
    NULL
  })

  if (is.null(nc)) {
    summary_results[[var_name]] <- list(status = "CONNECTION FAILED")
    next
  }

  time_var <- ncvar_get(nc, "day")
  dates <- as.Date(time_var, origin = "1900-01-01")
  last_available <- max(dates)
  lag_days <- as.numeric(today - last_available)

  cat("  Total days:", length(time_var), "\n")
  cat("  Last available:", as.character(last_available), "(lag:", lag_days, "days)\n")

  # Check specific recent dates
  test_dates <- seq(today - 5, today, by = 1)
  cat("  Recent dates:\n")
  for (test_date in test_dates) {
    days_ago <- as.numeric(today - test_date)
    available <- test_date %in% dates
    status <- if (available) "+" else "-"
    cat("    ", status, as.character(test_date), "(today -", days_ago, ")\n")
  }

  if ((today - 2) > last_available) {
    gap_days <- as.numeric((today - 2) - last_available)
    cat("  GAP:", gap_days, "day(s) missing\n")
    summary_results[[var_name]] <- list(status = "GAP", lag = lag_days, gap = gap_days)
  } else {
    cat("  OK\n")
    summary_results[[var_name]] <- list(status = "OK", lag = lag_days, gap = 0)
  }

  nc_close(nc)
  cat("\n")
}

cat("=================================================\n")
cat("SUMMARY\n")
cat("=================================================\n")
cat(sprintf("  %-8s  %-6s  %s\n", "Variable", "Lag", "Status"))
cat(sprintf("  %-8s  %-6s  %s\n", "--------", "---", "------"))
for (var_name in names(summary_results)) {
  r <- summary_results[[var_name]]
  if (r$status == "CONNECTION FAILED") {
    cat(sprintf("  %-8s  %-6s  %s\n", toupper(var_name), "?", "CONNECTION FAILED"))
  } else if (r$status == "GAP") {
    cat(sprintf("  %-8s  %-6s  %s\n", toupper(var_name), paste0(r$lag, "d"), paste0("GAP (", r$gap, " day(s) missing)")))
  } else {
    cat(sprintf("  %-8s  %-6s  %s\n", toupper(var_name), paste0(r$lag, "d"), "OK"))
  }
}
cat("=================================================\n")
