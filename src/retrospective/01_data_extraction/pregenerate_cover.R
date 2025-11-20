# 01a_pregenerate_cover.R

# Purpose: To pre-generate classified (forest/non-forest) vegetation rasters
# for each US L3 Ecoregion. This is a one-time pre-processing step that
# makes downstream scripts more efficient.

library(terra)
library(tidyverse)
library(glue)

# --- 1. Configuration ---

# Input files
# Using the path from the working map_forecast_danger.R script
landfire_conus_file <- "data/LF2023_EVT_240_CONUS/Tif/4326/LC23_EVT_240.tif"
ecoregions_file <- "data/us_eco_l3/us_eco_l3.shp"

# Output directory
output_dir <- "data/classified_cover"
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# --- 2. Load Main Data & Prepare Rules ---

message("Loading main LANDFIRE and Ecoregion data...")
tryCatch(
  {
    landfire_rast <- rast(landfire_conus_file)
  },
  error = function(e) {
    stop(paste("Failed to load LANDFIRE raster. Check path:", landfire_conus_file, "\nOriginal error:", e$message))
  }
)

tryCatch(
  {
    ecoregions <- vect(ecoregions_file)
  },
  error = function(e) {
    stop(paste("Failed to load Ecoregions shapefile. Check path:", ecoregions_file, "\nOriginal error:", e$message))
  }
)

message("Preparing reclassification rules from LANDFIRE categories...")
activeCat(landfire_rast) <- "EVT_LF"
categories_df <- levels(landfire_rast)[[1]]

if (is.null(categories_df) || nrow(categories_df) == 0) {
  stop("Could not read category levels from LANDFIRE raster. The raster may be missing its Raster Attribute Table.")
}

# Add a new column with the desired classification: 1 for non_forest, 2 for forest.
categories_df <- categories_df %>%
  mutate(veg_class_id = case_match(
    EVT_LF,
    c("Herb", "Shrub", "Sparse") ~ 1,
    "Tree" ~ 2,
    .default = NA_integer_
  ))

# Create the reclassification matrix
rcl_matrix <- categories_df[, c("Value", "veg_class_id")]

# Define new category labels for the output raster
new_levels <- data.frame(
  ID = c(1, 2),
  cover = c("non_forest", "forest")
)

# --- 3. Loop, Process, and Save ---

ecoregion_codes <- unique(ecoregions$US_L3CODE)
message(paste("Found", length(ecoregion_codes), "ecoregions to process."))

for (eco_code in ecoregion_codes) {
  message(paste("--- Processing Ecoregion:", eco_code, "---"))

  output_file <- file.path(output_dir, glue("ecoregion_{eco_code}_classified.tif"))

  if (file.exists(output_file)) {
    message("Output file already exists. Skipping.")
    next
  }

  ecoregion_poly <- ecoregions[ecoregions$US_L3CODE == eco_code, ]
  ecoregion_poly_proj <- project(ecoregion_poly, crs(landfire_rast))

  message("Cropping and masking LANDFIRE data...")
  ecoregion_landfire <- tryCatch(
    {
      crop(landfire_rast, ecoregion_poly_proj, snap = "out") %>%
        mask(ecoregion_poly_proj)
    },
    error = function(e) {
      message(paste("Warning: Could not crop/mask ecoregion", eco_code, ". Skipping. Error:", e$message))
      return(NULL)
    }
  )

  if (is.null(ecoregion_landfire)) {
    next
  }

  message("Reclassifying into forest/non-forest...")
  classified_rast <- classify(ecoregion_landfire, rcl = rcl_matrix, right = NA)
  levels(classified_rast) <- new_levels

  message(paste("Saving output to:", output_file))
  writeRaster(classified_rast, output_file, overwrite = TRUE, datatype = "INT1U")
}

message("--- All ecoregions processed. ---")
