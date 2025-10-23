# 01b_create_forecast_template.R

# Purpose: To pre-generate a large, empty, compressed NetCDF file to serve as a
# template for daily forecast runs for a specific ecoregion. This is a one-time
# setup step that speeds up the operational script by removing the slow
# pre-allocation step.

library(terra)
library(rcdo)
library(glue)

# --- Configuration ---

# Define the classified cover raster that will define the grid.
# This is for the Middle Rockies (Ecoregion 17).
classified_cover_file <- "data/classified_cover/ecoregion_17_classified.tif"

# This should match the desired number of forecast days (29 = today + 7 forecast days).
NUM_LAYERS <- 8

# Define the output directory and final template file path.
output_dir <- "data/templates"
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
output_template_file <- file.path(output_dir, "middle_rockies_forecast_shell.nc")

# --- Main ---

message("Creating forecast template shell for the Middle Rockies...")

# 1. Check for input file
if (!file.exists(classified_cover_file)) {
  stop(paste(
    "Input file not found:", classified_cover_file,
    "\nPlease run src/01a_pregenerate_cover.R first."
  ))
}

# 2. Create a single-layer template raster from the cover file's grid
message("Creating single-layer grid template...")
grid_template <- rast(classified_cover_file)
values(grid_template) <- NA
temp_template_file <- tempfile(fileext = ".nc")
writeCDF(grid_template, temp_template_file, overwrite = TRUE, varname = "fire_danger")

# 3. Use cdo duplicate to create the multi-layer, compressed shell file
message(paste("Using CDO to create a", NUM_LAYERS, "layer compressed template..."))
cdo_duplicate(temp_template_file, ndup = NUM_LAYERS, ofile = output_template_file) |>
  cdo_execute(options = "-z zip_1")

# 5. Clean up the temporary single-layer file
unlink(temp_template_file)

message(paste("Successfully created template file at:", output_template_file))
message("Template creation complete.")
