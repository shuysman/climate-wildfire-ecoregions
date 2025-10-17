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
# --- Force GDAL/Terra to use a local temp directory ---
# This is a more robust method than just terraOptions() as it forces the underlying
# GDAL library to use the specified directory, which is crucial on systems
# where /tmp is a RAM disk (tmpfs).
temp_dir <- file.path(getwd(), "tmp")
if (!dir.exists(temp_dir)) {
  dir.create(temp_dir)
}
# Set the environment variable for GDAL
Sys.setenv(GDAL_TMPDIR = temp_dir)
# Set the terra options as well for good measure
terraOptions(tempdir = temp_dir)


bin_rast <- function(new_rast, quants_rast, probs) {
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

out_dir <- file.path("./out/forecasts")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## Optimal rolling windows determined by dryness analysis script

probs <- seq(.01, 1.0, by = .01)

middle_rockies <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Middle Rockies")

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

dates <- time(vpd_series)


# Create temporary files for intermediate rasters to reduce memory usage
# These files will be written to the session's temporary directory and cleaned up automatically
forest_data_file <- tempfile(fileext = ".tif")
non_forest_data_file <- tempfile(fileext = ".tif")
forest_danger_file <- tempfile(fileext = ".tif")
non_forest_danger_file <- tempfile(fileext = ".tif")

message("Calculating rolling averages and writing to temporary files...")
forest_data <- terra::roll(vpd_series, n = 15, fun = mean, type = "to", circular = FALSE, filename = forest_data_file, wopt=list(gdal=c("COMPRESS=NONE")))
non_forest_data <- terra::roll(vpd_series, n = 5, fun = mean, type = "to", circular = FALSE, filename = non_forest_data_file, wopt=list(gdal=c("COMPRESS=NONE")))

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

message("Applying fire danger models...")

# Create an empty shell raster on disk for the output
message("Pre-allocating output files on disk...")
forest_fire_danger_rast <- rast(forest_data) # Use forest_data as a template
values(forest_fire_danger_rast) <- NA # Set all values to NA
writeRaster(forest_fire_danger_rast, forest_danger_file, overwrite = TRUE, wopt=list(gdal=c("COMPRESS=NONE")))
forest_fire_danger_rast <- rast(forest_danger_file) # Re-open the file for updating

non_forest_fire_danger_rast <- rast(non_forest_data)
values(non_forest_fire_danger_rast) <- NA
writeRaster(non_forest_fire_danger_rast, non_forest_danger_file, overwrite = TRUE, wopt=list(gdal=c("COMPRESS=NONE")))
non_forest_fire_danger_rast <- rast(non_forest_danger_file)

# Process layer by layer to conserve memory
for (i in 1:nlyr(forest_data)) {
  message(paste("Processing forest layer", i, "of", nlyr(forest_data)))
  layer_in <- subset(forest_data, i)
  layer_out <- process_forest_layer(layer_in)
  # Use replacement method to write to the correct layer on disk
  forest_fire_danger_rast[[i]] <- layer_out
}

for (i in 1:nlyr(non_forest_data)) {
  message(paste("Processing non-forest layer", i, "of", nlyr(non_forest_data)))
  layer_in <- subset(non_forest_data, i)
  layer_out <- process_non_forest_layer(layer_in)
  # Use replacement method to write to the correct layer on disk
  non_forest_fire_danger_rast[[i]] <- layer_out
}

time(forest_fire_danger_rast) <- dates

time(non_forest_fire_danger_rast) <- dates

cover_types <- rast("data/LF2023_EVT_240_CONUS/Tif/4326/LC23_EVT_240.tif") %>%
  crop(forest_fire_danger_rast)

activeCat(cover_types) <- "EVT_LF"

# 1. Extract the category levels into a data frame
# The [[1]] is used because levels() returns a list, one for each layer.
categories_df <- levels(cover_types)[[1]]

# 2. Add a new column with the desired classification using your rules
# We will create numeric codes: 1 for non_forest, 2 for forest.
# Everything else will become NA.
categories_df <- categories_df %>%
  mutate(veg_class_id = case_match(
    EVT_LF,
    c("Herb", "Shrub", "Sparse") ~ 1,
    "Tree" ~ 2,
    .default = NA_integer_
  ))

# 3. Create the reclassification matrix from the original ID to the new ID
# The matrix should have two columns: 'from' (original ID) and 'to' (new ID).
# The original raster values are in the 'ID' or 'value' column of the levels table.
rcl_matrix <- categories_df[, c("Value", "veg_class_id")]

# 4. Classify the raster using this matrix
classified_rast <- classify(cover_types, rcl = rcl_matrix, right = NA)

# 5. (Optional but recommended) Assign new category labels to the output raster
new_levels <- data.frame(
  ID = c(1, 2),
  cover = c("non_forest", "forest")
)
levels(classified_rast) <- new_levels

# Create high-resolution masks
forest_mask <- classified_rast == 2
forest_mask <- subst(forest_mask, FALSE, NA)
non_forest_mask <- classified_rast == 1
non_forest_mask <- subst(non_forest_mask, FALSE, NA)

# Get basemap based on the high-resolution grid
basemap <- get_tiles(classified_rast, provider = "Esri.NatGeoWorldMap", zoom = 9) %>%
  crop(classified_rast)

# Define new temp files for the resampled outputs
resampled_forest_file <- tempfile(fileext = ".tif")
resampled_non_forest_file <- tempfile(fileext = ".tif")

message("Upsampling forecast rasters to cover resolution...")
# Upsample the data to the mask resolution, writing to disk memory-safely
forest_fire_danger_rast <- resample(forest_fire_danger_rast, classified_rast, threads = TRUE, filename = resampled_forest_file, overwrite = TRUE, wopt=list(gdal=c("COMPRESS=NONE")))

non_forest_fire_danger_rast <- resample(non_forest_fire_danger_rast, classified_rast, threads = TRUE, filename = resampled_non_forest_file, overwrite = TRUE, wopt=list(gdal=c("COMPRESS=NONE")))


names(forest_fire_danger_rast) <- time(forest_fire_danger_rast)
names(non_forest_fire_danger_rast) <- time(non_forest_fire_danger_rast)

# Define a temp file for the combined output
combined_rast_file <- tempfile(fileext = ".tif")

message("Combining forest and non-forest rasters to disk...")
combined_fire_danger_rast <- ifel(classified_rast == 2, 
                                  forest_fire_danger_rast, 
                                  non_forest_fire_danger_rast,
                                  filename = combined_rast_file,
                                  overwrite = TRUE,
                                  wopt=list(gdal=c("COMPRESS=NONE"))
)

message("Creating forecast maps...")
ggplot() +
  geom_spatraster_rgb(data = basemap) +
  geom_spatraster(data = subset(combined_fire_danger_rast, time(combined_fire_danger_rast) >= today)) +
  scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  facet_wrap(~lyr, ncol = 5) +
  theme(axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1)) +
  labs(title = glue("Wildfire danger forecast for YELL/GRTE/JODR from {today}"), fill = "Proportion of Fires") +
  scale_x_continuous(expand = c(0, 0)) +
  scale_y_continuous(expand = c(0, 0))
ggsave(file.path(out_dir, glue("YELL-GRTE-JODR_fire_danger_forecast_{today}.png")), width = 12, height = 20)

message("Saving final forecast raster...")
forecast_rast <- subset(combined_fire_danger_rast, time(combined_fire_danger_rast) %in% dates[15:length(dates)]) ### Filter out early dates because the earliest date without NAs for forest is start_date + 14 due to rolling window calculation
terra::writeCDF(forecast_rast, file.path(out_dir, glue("fire_danger_forecast_{today}.nc")), overwrite = TRUE)


message("Forecast generation complete.")
