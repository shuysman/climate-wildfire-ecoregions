#!/usr/bin/env Rscript
# Generate index.html landing page with links to all enabled ecoregions
#
# This R script replaces generate_index_html.sh, using jinjar templates
# for cleaner HTML generation.

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

project_dir <- here()
output_file <- here("out", "forecasts", "index.html")

message("=========================================")
message("Generating index landing page")
message(glue("Date: {Sys.Date()}"))
message("=========================================")

# ============================================================================
# PREPARE DATA CONTEXT
# ============================================================================

# Load enabled ecoregions from config
context <- prepare_index_context(project_dir)

if (length(context$ecoregions) == 0) {
  stop("No enabled ecoregions found in config/ecoregions.yaml")
}

message(glue("Found {length(context$ecoregions)} enabled ecoregions"))

# ============================================================================
# RENDER TEMPLATE
# ============================================================================

html <- render_template("index.jinja2", context)

# Create output directory if needed
dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)

# Write output
writeLines(html, output_file)

message("=========================================")
message("Successfully generated index.html")
message(glue("Output: {output_file}"))
message("Linked ecoregions:")
for (eco in context$ecoregions) {
  message(glue("  - {eco$name}"))
}
message("=========================================")
