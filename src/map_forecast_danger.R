### Proof of concept script illustrating how to map wildfire ignition
### danger. Percentile of n-day rolling sum of VPD is estimated by
### comparing rolling sums of VPD to precalculated quantiles of VPD.
### This enables more rapid estimation of percentiles with low memory
### requirements to allow for estimation across large areas which
### would otherwise by memory-limited. Wildfire ignition danger is
### represented as a value from 0-1, which are the historical
### proportion of wildfires that burned at or below the corresponding
### percentile of dryness.

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(maptiles)
library(climateR)
library(ncdf4)
library(rcdo)

# Record start time
start_time <- Sys.time()

# Current Ecoregion
# Hardcoded to Middle Rockies for now. Should be set for each ecoregion dynamically when batched for other areas
ecoregion_name <- "Middle Rockies"
# Cleaned name for machine-readable access, i.e., for filenames
ecoregion_name_clean <- str_to_lower(str_replace_all(ecoregion_name, " ", "_"))


bin_rast <- function(new_rast, quants_rast, probs) {
  # Approximate conversion of percentile of dryness (VPD) to proportion of historical fires that burned at or above that %ile of VPD (fire danger)
  # Count how many quantile layers the new value is greater than.
  # This results in a raster of integers from 0 to 9.
  bin_index_rast <- sum(new_rast > quants_rast)

  # Now, map this integer index back to a percentile value.
  # We need a mapping from [0, 1, 2, ..., 9] to [0, 0.1, 0.2, ..., 0.9]
  # A value of 0 means it was smaller than the 1st quantile (q_0.1)
  # A value of 9 means it was larger than the 9th quantile (q_0.9)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)

  # Use classify to create the final approximate percentile raster
  percentile_rast_binned <- classify(bin_index_rast, rcl = rcl_matrix)

  return(percentile_rast_binned)
}


terraOptions(
  verbose = FALSE,
  memfrac = 0.9
)

nthreads <- 16

out_dir <- file.path("./out/forecasts")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## Optimal rolling windows determined by dryness analysis script

probs <- seq(.01, 1.0, by = .01)

middle_rockies <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == ecoregion_name)

forest_quants_rast <- rast("./out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-quants.nc")
non_forest_quants_rast <- rast("./out/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-5-VPD-quants.nc")


### Today's Forecast File
vpd_forecast_0 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_0.nc")
time(vpd_forecast_0) <- as_date(depth(vpd_forecast_0), origin = "1900-01-01")

### Yesterday's Forecast File
vpd_forecast_1 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_1.nc")
time(vpd_forecast_1) <- as_date(depth(vpd_forecast_1), origin = "1900-01-01")

### Two Day old Forecast File
vpd_forecast_2 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_2.nc")
time(vpd_forecast_2) <- as_date(depth(vpd_forecast_2), origin = "1900-01-01")

middle_rockies <- project(middle_rockies, crs(vpd_forecast_0))

# Rasterize the ecoregion polygon to create a processing mask
message("Rasterizing ecoregion polygon for masking...")
processing_mask <- rasterize(middle_rockies, vpd_forecast_0)

vpd_forecast_0 <- crop(vpd_forecast_0, middle_rockies)
vpd_forecast_1 <- crop(vpd_forecast_1, middle_rockies)
vpd_forecast_2 <- crop(vpd_forecast_2, middle_rockies)

### Retrieve historical gridMET data through today - 2
today <- today()
start_date <- today - 40

### Check if most recent forecast is available or raise error
### Most recent forecast should be vpd_forecast_0 which starts from tomorrow
most_recent_forecast <- time(subset(vpd_forecast_0, 1))
if (most_recent_forecast != today + 1) {
  stop(glue("Most recent forecast date is {most_recent_forecast} but should be {most_recent_forecast + 1}. Exiting..."))
}

vpd_gridmet <- tryCatch(
  {
    getGridMET(
      AOI = middle_rockies,
      varname = "vpd",
      startDate = start_date,
      endDate = today - 2,
      verbose = TRUE
    )$daily_mean_vapor_pressure_deficit %>%
      project(crs(vpd_forecast_0)) %>%
      crop(vpd_forecast_0)
  },
  error = function(e) {
    warning("Failed to retrieve gridMET data. Using older forecast data as a fallback. Forecast accuracy may be reduced.")
    # Fallback to using older forecast data
    c(
      subset(vpd_forecast_2, time(vpd_forecast_2) < today - 1),
      subset(vpd_forecast_1, time(vpd_forecast_1) < today)
    )
  }
)


today_vpd <- subset(vpd_forecast_1, time(vpd_forecast_1) == today)
yesterday_vpd <- subset(vpd_forecast_2, time(vpd_forecast_2) == today - 1)
vpd_series <- c(vpd_gridmet, yesterday_vpd, today_vpd, vpd_forecast_0)


# Create temporary files for intermediate rasters to reduce memory usage
# These files will be written to the session's temporary directory and cleaned up automatically
forest_data_file <- tempfile(fileext = ".tif")
non_forest_data_file <- tempfile(fileext = ".tif")
forest_danger_file <- tempfile(fileext = ".tif")
non_forest_danger_file <- tempfile(fileext = ".tif")

message("Calculating rolling averages and writing to temporary files...")
forest_data <- terra::roll(vpd_series, n = 15, fun = mean, type = "to", circular = FALSE, filename = forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>% subset(time(.) >= today())
non_forest_data <- terra::roll(vpd_series, n = 5, fun = mean, type = "to", circular = FALSE, filename = non_forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>% subset(time(.) >= today())

dates <- time(forest_data)

# Define functions to process each layer (binning + ecdf)
forest_fire_danger_ecdf <- readRDS("./out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-ecdf.RDS")
process_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, forest_quants_rast, probs)
  terra::app(percentile_rast, fun = forest_fire_danger_ecdf)
}

non_forest_fire_danger_ecdf <- readRDS("./out/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-5-VPD-ecdf.RDS")
process_non_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, non_forest_quants_rast, probs)
  terra::app(percentile_rast, fun = non_forest_fire_danger_ecdf)
}

# --- Streaming Pipeline to Process Data Day-by-Day ---

# --- Load Pre-generated Classified Cover Raster ---
# This file is created by the src/01a_pregenerate_cover.R script
message("Loading pre-generated classified cover raster for ecoregion 17...")
# NOTE: This is hardcoded to Middle Rockies (17) for now.
# A more advanced version would determine the ecoregion dynamically.
classified_rast_file <- "out/classified_cover/ecoregion_17_classified.tif"
if (!file.exists(classified_rast_file)) {
  stop(paste("Classified cover file not found:", classified_rast_file, "\nPlease run src/01a_pregenerate_cover.R first."))
}
classified_rast <- rast(classified_rast_file) %>% project(crs(forest_data))

# 2. Copy the pre-generated template file for today's forecast
message("Copying pre-generated template for today's forecast...")
template_file <- "out/templates/middle_rockies_forecast_shell.nc"
final_output_file <- file.path(out_dir, glue("fire_danger_forecast_{today}.nc"))

if (!file.exists(template_file)) {
  stop(paste(
    "Forecast template shell file not found:", template_file,
    "\nPlease run src/01b_create_forecast_template.R first."
  ))
}

file.copy(template_file, final_output_file, overwrite = TRUE)

# Re-open the newly copied file for writing into
final_output_rast <- rast(final_output_file)

# Set time and names for the output file immediately after creation
time(final_output_rast) <- dates
names(final_output_rast) <- dates

# Number of days in analysis
N_DAYS <- length(dates)

# 3. Loop through each day, process, and write to a temporary file
message(glue("Starting day-by-day processing pipeline for {N_DAYS} days..."))

# A list to store the filenames of the final processed layers
final_layer_files <- c()

for (i in 1:N_DAYS) {
  day <- dates[i]
  message(paste("Processing day", i, glue("of {N_DAYS} days ({day})...")))

  # --- Create iteration-specific temp files ---
  # This loop is designed to be maximally memory- and disk-efficient.
  # Each major step writes its output to a new temporary file on disk rather than
  # holding large intermediate rasters in RAM. This is critical for environments
  # with limited RAM or ephemeral storage (like AWS Fargate).
  resampled_forest_file <- tempfile(fileext = ".tif")
  resampled_nonforest_file <- tempfile(fileext = ".tif")
  combined_layer_file <- tempfile(fileext = ".tif")

  # Get single low-res layer for this day
  forest_layer_lowres <- subset(forest_data, time(forest_data) == day)
  nonforest_layer_lowres <- subset(non_forest_data, time(non_forest_data) == day)

  # Process it (binning + ecdf)
  processed_forest <- process_forest_layer(forest_layer_lowres)
  processed_nonforest <- process_non_forest_layer(nonforest_layer_lowres)

  # Resample, writing directly to disk (uncompressed is faster for these intermediate steps)
  resample(processed_forest, classified_rast, filename = resampled_forest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))
  resample(processed_nonforest, classified_rast, filename = resampled_nonforest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))

  # Combine, writing to a *compressed* temporary file to save disk space during the loop
  ifel(classified_rast == 2, rast(resampled_forest_file), rast(resampled_nonforest_file), filename = combined_layer_file, wopt = list(gdal = c("COMPRESS=DEFLATE")))

  # Add the final filename to our list. This file will be kept until the final assembly.
  final_layer_files <- c(final_layer_files, combined_layer_file)

  # Explicitly remove intermediate R objects and the uncompressed temp files for this iteration
  rm(forest_layer_lowres, nonforest_layer_lowres, processed_forest, processed_nonforest)
  unlink(c(resampled_forest_file, resampled_nonforest_file))
  gc()
}

# --- Assemble, Save, and Cleanup ---
message("Processing complete. Assembling final raster...")

# Create the final multi-layer raster. This is a memory-efficient "lazy load".
# It creates a SpatRaster object that points to the list of single-layer files on disk
# without loading all the pixel data into RAM.
final_output_rast <- rast(final_layer_files)

# Set the correct time information
time(final_output_rast) <- dates
names(final_output_rast) <- dates

# Save the final, compressed NetCDF file. This is the first time all the
# processed pixel data is read from the temporary files and written into a
# single, final file.
message("Saving final compressed NetCDF...")
writeCDF(final_output_rast, final_output_file, overwrite = TRUE, varname = "fire_danger", compression = 2)

# The plotting logic now uses the final raster
message("Creating forecast maps...")
basemap <- get_tiles(final_output_rast, provider = "Esri.NatGeoWorldMap", zoom = 9) %>%
  crop(final_output_rast)

ggplot() +
  geom_spatraster_rgb(data = basemap) +
  geom_spatraster(data = subset(final_output_rast, time(final_output_rast) >= today)) +
  scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  facet_wrap(~lyr, ncol = 5) +
  theme(axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1)) +
  labs(title = glue("Wildfire danger forecast for YELL/GRTE/JODR from {today}"), fill = "Proportion of Fires") +
  scale_x_continuous(expand = c(0, 0)) +
  scale_y_continuous(expand = c(0, 0))
ggsave(file.path(out_dir, glue("{ecoregion_name_clean}_fire_danger_forecast_{today}.png")), width = 20, height = 20)

# Now that the final file is saved, clean up all temporary files from the loop
message("Cleaning up intermediate files...")
unlink(c(forest_data_file, non_forest_data_file, final_layer_files))

message("Forecast generation complete.")

# Calculate and print total runtime
end_time <- Sys.time()
elapsed_time <- end_time - start_time
message(paste("Total script runtime:", format(elapsed_time)))
