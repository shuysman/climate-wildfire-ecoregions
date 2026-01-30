#!/usr/bin/env Rscript
# Generate per-ecoregion HTML dashboard
#
# This R script replaces generate_daily_html.sh, using jinjar templates
# for cleaner HTML generation with Jinja2-style templating.
#
# Usage: Rscript generate_daily_html.R [ecoregion]
#   ecoregion: Name of the ecoregion (default: middle_rockies or ECOREGION env var)

suppressPackageStartupMessages({
  library(jinjar)
  library(yaml)
  library(glue)
  library(here)
})

# Source template utilities
source(here("src", "operational", "html_generation", "R", "render_templates.R"))
source(here("src", "operational", "html_generation", "R", "template_data.R"))

# ============================================================================
# CONFIGURATION
# ============================================================================

# Get ecoregion from command line arguments or environment variable
args <- commandArgs(trailingOnly = TRUE)
ecoregion <- if (length(args) >= 1) {
  args[1]
} else {
  Sys.getenv("ECOREGION", unset = "middle_rockies")
}

project_dir <- here()
today <- Sys.Date()
yesterday <- today - 1

message("=========================================")
message(glue("Generating HTML dashboard for: {ecoregion}"))
message(glue("Date: {today}"))
message("=========================================")

# ============================================================================
# PREPARE DATA CONTEXT
# ============================================================================

# Use the prepare_dashboard_context function from template_data.R
context <- prepare_dashboard_context(
  ecoregion = ecoregion,
  forecast_date = today,
  project_dir = project_dir
)

# Add stale warning variables to root context for the template
if (context$stale_warning$has_stale_warning) {
  context$stale_variables <- context$stale_warning$stale_variables
  message(glue("Warning: Stale data detected for: {context$stale_variables}"))
}

message(glue("Ecoregion name: {context$ecoregion_name}"))
message(glue("Forecast map date: {context$forecast_map_date}"))
message(glue("Number of parks: {length(context$parks)}"))

# ============================================================================
# RENDER TEMPLATE
# ============================================================================

message("Rendering template...")

html <- render_template("daily_forecast.jinja2", context)

# ============================================================================
# WRITE OUTPUT
# ============================================================================

output_dir <- here("out", "forecasts", ecoregion)
output_file <- file.path(output_dir, "daily_forecast.html")

# Create output directory if needed
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Write output
writeLines(html, output_file)

message("=========================================")
message(glue("Successfully generated daily_forecast.html for {ecoregion}"))
message(glue("Output: {output_file}"))
message("=========================================")
