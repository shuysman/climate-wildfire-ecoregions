### Generalized wildfire ignition danger forecasting script
### Processes a single ecoregion based on configuration
### Percentile of n-day rolling sum is estimated by comparing to precalculated
### quantiles. This enables rapid estimation with low memory requirements.
### Wildfire ignition danger is represented as a value from 0-1, which are the
### historical proportion of wildfires that burned at or below the corresponding
### percentile of dryness.

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(maptiles)
library(climateR)
library(ncdf4)
library(rcdo)
library(yaml)

# Record start time
start_time <- Sys.time()

# ============================================================================
# CONFIGURATION - Load ecoregion from environment or command line
# ============================================================================

# Get ecoregion from environment variable (for AWS ECS) or command line args
ecoregion_name_clean <- Sys.getenv("ECOREGION", unset = NA)

if (is.na(ecoregion_name_clean)) {
  # Fallback to command line arguments
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) >= 1) {
    ecoregion_name_clean <- args[1]
  } else {
    # Default for backward compatibility
    ecoregion_name_clean <- "middle_rockies"
    warning("No ECOREGION environment variable or command line argument provided. Defaulting to middle_rockies.")
  }
}

message(glue("========================================"))
message(glue("Processing ecoregion: {ecoregion_name_clean}"))
message(glue("========================================"))

# Load configuration
config <- read_yaml("config/ecoregions.yaml")

# Find the ecoregion config
ecoregion_config <- NULL
for (eco in config$ecoregions) {
  if (eco$name_clean == ecoregion_name_clean && isTRUE(eco$enabled)) {
    ecoregion_config <- eco
    break
  }
}

if (is.null(ecoregion_config)) {
  stop(glue("Ecoregion '{ecoregion_name_clean}' not found or not enabled in config/ecoregions.yaml"))
}

# Extract configuration
ecoregion_id <- ecoregion_config$id
ecoregion_name <- ecoregion_config$name
forest_window <- ecoregion_config$cover_types$forest$window
forest_variable <- ecoregion_config$cover_types$forest$variable
forest_gridmet_var <- ecoregion_config$cover_types$forest$gridmet_varname
non_forest_window <- ecoregion_config$cover_types$non_forest$window
non_forest_variable <- ecoregion_config$cover_types$non_forest$variable
non_forest_gridmet_var <- ecoregion_config$cover_types$non_forest$gridmet_varname

message(glue("Ecoregion ID: {ecoregion_id}"))
message(glue("Ecoregion Name: {ecoregion_name}"))
message(glue("Forest predictor: {forest_window}-day {forest_variable}"))
message(glue("Non-forest predictor: {non_forest_window}-day {non_forest_variable}"))

# Validate that forest and non-forest use the same variable (for now)
if (forest_variable != non_forest_variable) {
  stop(glue("Forest and non-forest currently must use the same variable. Got {forest_variable} and {non_forest_variable}"))
}
primary_variable <- forest_variable

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

bin_rast <- function(new_rast, quants_rast, probs) {
  # Approximate conversion of percentile of dryness to proportion of historical fires
  bin_index_rast <- sum(new_rast > quants_rast)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)
  percentile_rast_binned <- classify(bin_index_rast, rcl = rcl_matrix)
  return(percentile_rast_binned)
}

# ============================================================================
# SETUP
# ============================================================================

terraOptions(verbose = FALSE, memfrac = 0.9)
nthreads <- 16
probs <- seq(.01, 1.0, by = .01)

# Create output directory for this ecoregion
today <- today()
out_dir <- file.path("./out/forecasts", ecoregion_name_clean, today)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ============================================================================
# LOAD ECOREGION-SPECIFIC DATA
# ============================================================================

message("Loading ecoregion boundary...")
ecoregion_boundary <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == ecoregion_name)

message("Loading quantile rasters...")
forest_quants_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-quants.nc")
non_forest_quants_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-quants.nc")

if (!file.exists(forest_quants_path)) {
  stop(glue("Forest quantile raster not found: {forest_quants_path}"))
}
if (!file.exists(non_forest_quants_path)) {
  stop(glue("Non-forest quantile raster not found: {non_forest_quants_path}"))
}

forest_quants_rast <- rast(forest_quants_path)
non_forest_quants_rast <- rast(non_forest_quants_path)

message("Loading eCDF models...")
forest_ecdf_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-ecdf.RDS")
non_forest_ecdf_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-ecdf.RDS")

if (!file.exists(forest_ecdf_path)) {
  stop(glue("Forest eCDF model not found: {forest_ecdf_path}"))
}
if (!file.exists(non_forest_ecdf_path)) {
  stop(glue("Non-forest eCDF model not found: {non_forest_ecdf_path}"))
}

forest_fire_danger_ecdf <- readRDS(forest_ecdf_path)
non_forest_fire_danger_ecdf <- readRDS(non_forest_ecdf_path)

message("Loading classified cover raster...")
classified_rast_file <- glue("data/classified_cover/ecoregion_{ecoregion_id}_classified.tif")
if (!file.exists(classified_rast_file)) {
  stop(glue("Classified cover file not found: {classified_rast_file}\nPlease run src/01a_pregenerate_cover.R first."))
}

# ============================================================================
# LOAD FORECAST DATA
# ============================================================================

message(glue("Loading {primary_variable} forecast data..."))

# Load forecast files for the primary variable
forecast_0_path <- glue("data/forecasts/{primary_variable}/cfsv2_metdata_forecast_{primary_variable}_daily_0.nc")
forecast_1_path <- glue("data/forecasts/{primary_variable}/cfsv2_metdata_forecast_{primary_variable}_daily_1.nc")
forecast_2_path <- glue("data/forecasts/{primary_variable}/cfsv2_metdata_forecast_{primary_variable}_daily_2.nc")

if (!file.exists(forecast_0_path)) {
  stop(glue("Forecast file not found: {forecast_0_path}\nPlease run src/update_all_forecasts.sh first."))
}

var_forecast_0 <- rast(forecast_0_path)
time(var_forecast_0) <- as_date(depth(var_forecast_0), origin = "1900-01-01")

var_forecast_1 <- rast(forecast_1_path)
time(var_forecast_1) <- as_date(depth(var_forecast_1), origin = "1900-01-01")

var_forecast_2 <- rast(forecast_2_path)
time(var_forecast_2) <- as_date(depth(var_forecast_2), origin = "1900-01-01")

# Project ecoregion boundary to forecast CRS
ecoregion_boundary <- project(ecoregion_boundary, crs(var_forecast_0))

# Rasterize the ecoregion polygon to create a processing mask
message("Rasterizing ecoregion polygon for masking...")
processing_mask <- rasterize(ecoregion_boundary, var_forecast_0)

# Crop forecasts to ecoregion extent
var_forecast_0 <- crop(var_forecast_0, ecoregion_boundary)
var_forecast_1 <- crop(var_forecast_1, ecoregion_boundary)
var_forecast_2 <- crop(var_forecast_2, ecoregion_boundary)

# ============================================================================
# RETRIEVE HISTORICAL DATA
# ============================================================================

start_date <- today - 40

### Check if most recent forecast is available or raise error
most_recent_forecast <- time(subset(var_forecast_0, 1))
if (most_recent_forecast != today + 1) {
  stop(glue("Most recent forecast date is {most_recent_forecast} but should be {today + 1}. Exiting..."))
}

# Define cache path
cache_dir <- "./out/cache"
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
gridmet_cache_file <- file.path(cache_dir, glue("{ecoregion_name_clean}_{primary_variable}_latest_gridmet.nc"))

message(glue("Fetching historical gridMET {primary_variable} data..."))

# Map variable name to gridMET output column name
gridmet_column_map <- list(
  vpd = "daily_mean_vapor_pressure_deficit",
  fm1000 = "daily_mean_dead_fuel_moisture_1000hr"
)

if (!primary_variable %in% names(gridmet_column_map)) {
  stop(glue("Unknown gridMET variable: {primary_variable}. Add mapping to gridmet_column_map."))
}

var_gridmet <- tryCatch(
  {
    message("Attempting to download fresh gridMET data...")
    fresh_gridmet <- getGridMET(
      AOI = ecoregion_boundary,
      varname = primary_variable,
      startDate = start_date,
      endDate = today - 2,
      verbose = TRUE
    )[[gridmet_column_map[[primary_variable]]]] %>%
      project(crs(var_forecast_0)) %>%
      crop(var_forecast_0)

    message("Successfully downloaded fresh gridMET data. Caching to NetCDF file.")
    writeCDF(fresh_gridmet, gridmet_cache_file, overwrite = TRUE, varname = primary_variable)

    fresh_gridmet
  },
  error = function(e) {
    warning(glue("Failed to retrieve fresh gridMET data: {e$message}"))

    if (file.exists(gridmet_cache_file)) {
      warning("Using cached gridMET data as a fallback. Data may be stale.")
      rast(gridmet_cache_file)
    } else {
      stop("Failed to retrieve gridMET data and no cache file is available. Cannot proceed.")
    }
  }
)

# ============================================================================
# INFILLING LOGIC - Create full time series
# ============================================================================

message("Creating full time series with historical and forecast data...")

var_series <- var_gridmet
last_hist_date <- max(time(var_series))
message(glue("Last historical date is {last_hist_date}"))

all_forecast_files <- list(var_forecast_2, var_forecast_1, var_forecast_0)
for (forecast_rast in all_forecast_files) {
  new_dates <- time(forecast_rast)[time(forecast_rast) > last_hist_date]
  if (length(new_dates) > 0) {
    message(glue("Infilling with {length(new_dates)} day(s) from a forecast file."))
    infill_layers <- subset(forecast_rast, time(forecast_rast) %in% new_dates)
    var_series <- c(var_series, infill_layers)
    last_hist_date <- max(time(var_series))
  }
}

# ============================================================================
# CALCULATE ROLLING AVERAGES
# ============================================================================

forest_data_file <- tempfile(fileext = ".tif")
non_forest_data_file <- tempfile(fileext = ".tif")

message("Calculating rolling averages and writing to temporary files...")
forest_data <- terra::roll(var_series, n = forest_window, fun = mean, type = "to", circular = FALSE, filename = forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
  subset(time(.) >= today & time(.) <= today + 7)
non_forest_data <- terra::roll(var_series, n = non_forest_window, fun = mean, type = "to", circular = FALSE, filename = non_forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
  subset(time(.) >= today & time(.) <= today + 7)

dates <- time(forest_data)

# ============================================================================
# DEFINE PROCESSING FUNCTIONS
# ============================================================================

process_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, forest_quants_rast, probs)
  terra::app(percentile_rast, fun = forest_fire_danger_ecdf)
}

process_non_forest_layer <- function(layer) {
  percentile_rast <- bin_rast(layer, non_forest_quants_rast, probs)
  terra::app(percentile_rast, fun = non_forest_fire_danger_ecdf)
}

# ============================================================================
# LOAD CLASSIFIED COVER AND PREPARE OUTPUT FILE
# ============================================================================

message(glue("Loading pre-generated classified cover raster for ecoregion {ecoregion_id}..."))
classified_rast <- rast(classified_rast_file) %>% project(crs(forest_data))

# Copy template file for today's forecast
message("Preparing output file...")
final_output_file <- file.path(out_dir, "fire_danger_forecast.nc")

# Number of days in analysis
N_DAYS <- length(dates)

# ============================================================================
# STREAMING PIPELINE - Process day-by-day
# ============================================================================

message(glue("Starting day-by-day processing pipeline for {N_DAYS} days..."))

final_layer_files <- c()

for (i in 1:N_DAYS) {
  day <- dates[i]
  message(paste("Processing day", i, glue("of {N_DAYS} days ({day})...")))

  resampled_forest_file <- tempfile(fileext = ".tif")
  resampled_nonforest_file <- tempfile(fileext = ".tif")
  combined_layer_file <- tempfile(fileext = ".tif")

  # Get single layer for this day
  forest_layer_lowres <- subset(forest_data, time(forest_data) == day)
  nonforest_layer_lowres <- subset(non_forest_data, time(non_forest_data) == day)

  # Process (binning + ecdf)
  processed_forest <- process_forest_layer(forest_layer_lowres)
  processed_nonforest <- process_non_forest_layer(nonforest_layer_lowres)

  # Resample to high resolution
  resample(processed_forest, classified_rast, filename = resampled_forest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))
  resample(processed_nonforest, classified_rast, filename = resampled_nonforest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))

  # Combine based on cover type
  ifel(classified_rast == 2, rast(resampled_forest_file), rast(resampled_nonforest_file), filename = combined_layer_file, wopt = list(gdal = c("COMPRESS=DEFLATE")))

  final_layer_files <- c(final_layer_files, combined_layer_file)

  # Cleanup
  rm(forest_layer_lowres, nonforest_layer_lowres, processed_forest, processed_nonforest)
  unlink(c(resampled_forest_file, resampled_nonforest_file))
  gc()
}

# ============================================================================
# ASSEMBLE AND SAVE FINAL RASTER
# ============================================================================

message("Processing complete. Assembling final raster...")

final_output_rast <- rast(final_layer_files)
time(final_output_rast) <- dates
names(final_output_rast) <- dates

message("Saving final compressed NetCDF...")
writeCDF(final_output_rast, final_output_file, overwrite = TRUE, varname = "fire_danger", compression = 2)

# ============================================================================
# CREATE FORECAST MAPS
# ============================================================================

message("Creating forecast maps...")
basemap <- get_tiles(final_output_rast, provider = "Esri.WorldTopoMap", zoom = 6, crop = TRUE, project = FALSE)

base_plot <- ggplot() +
  geom_spatraster_rgb(data = basemap, maxcell = Inf) +
  geom_spatraster(data = subset(final_output_rast, time(final_output_rast) >= today)) +
  scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  scale_x_continuous(expand = c(0, 0)) +
  scale_y_continuous(expand = c(0, 0))

# Desktop version
message("Saving desktop version...")
p_desktop <- base_plot +
  facet_wrap(~lyr, ncol = 4) +
  labs(title = glue("Wildfire danger forecast for {ecoregion_name} from {today}"), fill = "Proportion of Fires") +
  theme(
    legend.position = "bottom",
    legend.justification = "right",
    legend.box.spacing = unit(0.5, "cm"),
    plot.margin = margin(t = 20, r = 10, b = 15, l = 10, unit = "pt"),
    axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1, size = 14),
    axis.text.y = element_text(size = 16),
    axis.title = element_text(size = 18),
    plot.title = element_text(size = 22, margin = margin(b = 10)),
    strip.text = element_text(size = 16),
    legend.title = element_text(size = 20, margin = margin(r = 20, b = 20)),
    legend.text = element_text(size = 16),
    legend.key.width = unit(2, "cm"),
    legend.key.height = unit(0.5, "cm")
  )
ggsave(file.path(out_dir, "fire_danger_forecast.png"),
  plot = p_desktop, width = 20, height = 12, dpi = 300
)

# Mobile version
message("Saving mobile version...")
p_mobile <- base_plot +
  facet_wrap(~lyr, ncol = 2) +
  labs(
    title = "Wildfire danger forecast",
    subtitle = glue("{ecoregion_name} from {today}"), fill = "Proportion of Fires"
  ) +
  theme(
    legend.position = "bottom",
    legend.justification = "right",
    legend.box.spacing = unit(0.5, "cm"),
    plot.margin = margin(t = 25, r = 10, b = 20, l = 10, unit = "pt"),
    axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1, size = 18),
    axis.text.y = element_text(size = 20),
    axis.title = element_text(size = 22),
    plot.title = element_text(size = 26, margin = margin(b = 15)),
    plot.subtitle = element_text(size = 20),
    strip.text = element_text(size = 22),
    legend.title = element_text(size = 20, margin = margin(r = 20, b = 20)),
    legend.text = element_text(size = 20),
    legend.key.width = unit(1.5, "cm"),
    legend.key.height = unit(0.6, "cm")
  )
ggsave(file.path(out_dir, "fire_danger_forecast_mobile.png"),
  plot = p_mobile, width = 11.5, height = 22, dpi = 300
)

# ============================================================================
# CLEANUP
# ============================================================================

message("Cleaning up intermediate files...")
unlink(c(forest_data_file, non_forest_data_file, final_layer_files))

message("Forecast generation complete.")

# Calculate and print total runtime
end_time <- Sys.time()
elapsed_time <- end_time - start_time
message(glue("Total script runtime: {format(elapsed_time)}"))
message(glue("Output directory: {out_dir}"))
