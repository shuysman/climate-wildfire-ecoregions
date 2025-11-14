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

# Note: Forest and non-forest can now use different variables
# This supports ecoregions like Canadian Rockies (FM1000 forest, CWD non-forest)
message(glue("Forest predictor: {forest_variable} ({forest_window}-day window)"))
message(glue("Non-forest predictor: {non_forest_variable} ({non_forest_window}-day window)"))

# Create display names for title
get_variable_display_name <- function(var) {
  switch(var,
    "vpd" = "VPD",
    "fm1000" = "FM1000",
    "fm1000inv" = "FM1000",
    "fm100" = "FM100",
    "erc" = "ERC",
    "cwd" = "CWD",
    toupper(var)  # fallback to uppercase
  )
}

forest_display_name <- get_variable_display_name(forest_variable)
non_forest_display_name <- get_variable_display_name(non_forest_variable)

# For map title - use forest variable or indicate both if different
if (forest_variable == non_forest_variable) {
  variable_display_name <- forest_display_name
} else {
  variable_display_name <- glue("{forest_display_name}/{non_forest_display_name}")
}

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

# Function to load forecast for a variable
load_forecast_data <- function(var_name, label, boundary = NULL) {
  message(glue("Loading {var_name} forecast data for {label} areas..."))

  forecast_0_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_0.nc")
  forecast_1_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_1.nc")
  forecast_2_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_2.nc")

  if (!file.exists(forecast_0_path)) {
    stop(glue("{label} forecast file not found: {forecast_0_path}\nPlease run src/update_all_forecasts.sh first."))
  }

  forecast_0 <- rast(forecast_0_path)
  time(forecast_0) <- as_date(depth(forecast_0), origin = "1900-01-01")

  forecast_1 <- rast(forecast_1_path)
  time(forecast_1) <- as_date(depth(forecast_1), origin = "1900-01-01")

  forecast_2 <- rast(forecast_2_path)
  time(forecast_2) <- as_date(depth(forecast_2), origin = "1900-01-01")

  # Crop to ecoregion extent if boundary provided
  if (!is.null(boundary)) {
    forecast_0 <- crop(forecast_0, boundary)
    forecast_1 <- crop(forecast_1, boundary)
    forecast_2 <- crop(forecast_2, boundary)
  }

  return(list(f0 = forecast_0, f1 = forecast_1, f2 = forecast_2))
}

# Load forest forecasts (without cropping yet)
forest_forecasts <- load_forecast_data(forest_gridmet_var, "forest")

# Project ecoregion boundary to forecast CRS (use forest forecast as reference)
ecoregion_boundary <- project(ecoregion_boundary, crs(forest_forecasts$f0))

# Now crop the forest forecasts to the projected boundary
forest_forecasts$f0 <- crop(forest_forecasts$f0, ecoregion_boundary)
forest_forecasts$f1 <- crop(forest_forecasts$f1, ecoregion_boundary)
forest_forecasts$f2 <- crop(forest_forecasts$f2, ecoregion_boundary)

# Load non-forest forecasts (reuse forest if same variable)
if (forest_gridmet_var == non_forest_gridmet_var) {
  message("Forest and non-forest use same variable - reusing forecast data")
  non_forest_forecasts <- forest_forecasts
} else {
  # Load with cropping since boundary is now projected
  non_forest_forecasts <- load_forecast_data(non_forest_gridmet_var, "non-forest", ecoregion_boundary)
}

# ============================================================================
# RETRIEVE HISTORICAL DATA
# ============================================================================

start_date <- today - 40

### Check if most recent forecast is available or raise error
forest_most_recent <- time(subset(forest_forecasts$f0, 1))

# Accept forecasts starting either today or tomorrow
# - Aggregated variables (VPD) typically start tomorrow
# - Ensemble variables (FM1000) typically start today
if (forest_most_recent != today + 1 && forest_most_recent != today) {
  stop(glue("Forest forecast date is {forest_most_recent} but should be either {today} or {today + 1}. Exiting..."))
}

if (forest_most_recent == today) {
  message(glue("Note: Forest forecast starts today ({today}) instead of tomorrow. This is expected for ensemble variables like FM1000."))
}

# Check non-forest forecast date if different variable
if (forest_gridmet_var != non_forest_gridmet_var) {
  non_forest_most_recent <- time(subset(non_forest_forecasts$f0, 1))

  if (non_forest_most_recent != today + 1 && non_forest_most_recent != today) {
    stop(glue("Non-forest forecast date is {non_forest_most_recent} but should be either {today} or {today + 1}. Exiting..."))
  }

  if (non_forest_most_recent == today) {
    message(glue("Note: Non-forest forecast starts today ({today}) instead of tomorrow. This is expected for ensemble variables."))
  }
}

# Define cache directory
cache_dir <- "./out/cache"
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)

# Map variable name to gridMET output column name
gridmet_column_map <- list(
  vpd = "daily_mean_vapor_pressure_deficit",
  fm1000 = "dead_fuel_moisture_1000hr",
  cwd = "climatic_water_deficit"
)

# Function to fetch gridMET data for a variable
fetch_gridmet_data <- function(var_name, label, reference_raster) {
  message(glue("Fetching historical gridMET {var_name} data for {label} areas..."))

  cache_file <- file.path(cache_dir, glue("{ecoregion_name_clean}_{var_name}_latest_gridmet.nc"))

  if (!var_name %in% names(gridmet_column_map)) {
    stop(glue("Unknown gridMET variable: {var_name}. Add mapping to gridmet_column_map."))
  }

  gridmet_data <- tryCatch(
    {
      message("Attempting to download fresh gridMET data...")
      fresh_gridmet <- getGridMET(
        AOI = ecoregion_boundary,
        varname = var_name,
        startDate = start_date,
        endDate = today - 2,
        verbose = TRUE
      )[[gridmet_column_map[[var_name]]]] %>%
        project(crs(reference_raster)) %>%
        crop(reference_raster)

      message("Successfully downloaded fresh gridMET data. Caching to NetCDF file.")
      writeCDF(fresh_gridmet, cache_file, overwrite = TRUE, varname = var_name)

      fresh_gridmet
    },
    error = function(e) {
      warning(glue("Failed to retrieve fresh gridMET data: {e$message}"))

      if (file.exists(cache_file)) {
        warning("Using cached gridMET data as a fallback. Data may be stale.")
        rast(cache_file)
      } else {
        stop("Failed to retrieve gridMET data and no cache file is available. Cannot proceed.")
      }
    }
  )

  return(gridmet_data)
}

# Fetch forest gridMET data
forest_gridmet <- fetch_gridmet_data(forest_gridmet_var, "forest", forest_forecasts$f0)

# Fetch non-forest gridMET data (reuse forest if same variable)
if (forest_gridmet_var == non_forest_gridmet_var) {
  message("Reusing gridMET data for non-forest")
  non_forest_gridmet <- forest_gridmet
} else {
  non_forest_gridmet <- fetch_gridmet_data(non_forest_gridmet_var, "non-forest", non_forest_forecasts$f0)
}

# ============================================================================
# INFILLING LOGIC - Create full time series
# ============================================================================

# Function to create timeseries by infilling historical data with forecasts
create_timeseries <- function(gridmet_data, forecasts, var_name, label) {
  message(glue("Creating {label} timeseries ({var_name})..."))

  series <- gridmet_data
  last_date <- max(time(series))
  message(glue("  Last historical date: {last_date}"))

  # Infill with forecast data (f2, f1, f0 in that order for proper rotation)
  forecast_list <- list(forecasts$f2, forecasts$f1, forecasts$f0)
  for (forecast_rast in forecast_list) {
    new_dates <- time(forecast_rast)[time(forecast_rast) > last_date]
    if (length(new_dates) > 0) {
      message(glue("  Infilling with {length(new_dates)} day(s) from forecast file"))
      infill_layers <- subset(forecast_rast, time(forecast_rast) %in% new_dates)
      series <- c(series, infill_layers)
      last_date <- max(time(series))
    }
  }

  # Apply variable-specific transformations
  if (var_name == "fm1000") {
    message(glue("  Inverting FM1000 to (100 - FM1000) for correct fire risk relationship"))
    series <- 100 - series
  }
  # Add other transformations here as needed (e.g., CWD inversion if required)

  message(glue("  {label} timeseries complete: {min(time(series))} to {max(time(series))}"))
  return(series)
}

# Create forest timeseries
forest_series <- create_timeseries(forest_gridmet, forest_forecasts, forest_gridmet_var, "forest")

# Create non-forest timeseries (reuse forest if same variable)
if (forest_gridmet_var == non_forest_gridmet_var) {
  message("Reusing forest timeseries for non-forest")
  non_forest_series <- forest_series
} else {
  non_forest_series <- create_timeseries(non_forest_gridmet, non_forest_forecasts, non_forest_gridmet_var, "non-forest")
}

# ============================================================================
# TIMESERIES VALIDATION
# ============================================================================

# Validation helper function
validate_timeseries <- function(series, label, window) {
  message(glue("Validating {label} timeseries..."))

  series_dates <- time(series)
  n_dates <- length(series_dates)

  # Check 1: Duplicate dates detection
  if (any(duplicated(series_dates))) {
    duplicate_dates <- series_dates[duplicated(series_dates)]
    stop(glue("ERROR: Duplicate dates found in {label} timeseries: {paste(duplicate_dates, collapse=', ')}\n",
              "This would corrupt rolling window calculations. Check forecast file downloads."))
  }
  message(glue("  ✓ No duplicate dates ({n_dates} unique dates)"))

  # Check 2: Date ordering verification
  sorted_dates <- sort(series_dates)
  if (!identical(series_dates, sorted_dates)) {
    stop(glue("ERROR: {label} dates not in chronological order.\n",
              "First date: {series_dates[1]}, Last date: {series_dates[n_dates]}"))
  }
  message(glue("  ✓ Dates in chronological order"))

  # Check 3: Gap detection (continuous daily sequence)
  expected_sequence <- seq(from = series_dates[1], to = series_dates[n_dates], by = "1 day")
  n_expected <- length(expected_sequence)

  if (n_dates != n_expected) {
    missing_dates <- setdiff(expected_sequence, series_dates)
    stop(glue("ERROR: Gaps detected in {label} timeseries. Expected {n_expected} days, found {n_dates} days.\n",
              "Missing dates: {paste(head(missing_dates, 10), collapse=', ')}{ifelse(length(missing_dates) > 10, '...', '')}"))
  }
  message(glue("  ✓ Continuous daily sequence ({n_dates} days from {series_dates[1]} to {series_dates[n_dates]})"))

  # Check 4: Sufficient data for rolling windows
  forecast_start_date <- today
  forecast_end_date <- today + 7
  min_required_start_date <- forecast_start_date - window + 1

  if (series_dates[1] > min_required_start_date) {
    stop(glue("ERROR: Insufficient {label} historical data for rolling window calculation.\n",
              "Window size: {window} days\n",
              "Data starts: {series_dates[1]}\n",
              "Required start date: {min_required_start_date} or earlier\n",
              "Missing {as.numeric(series_dates[1] - min_required_start_date)} days of historical data."))
  }

  if (series_dates[n_dates] < forecast_end_date) {
    stop(glue("ERROR: Insufficient {label} forecast data.\n",
              "Data ends: {series_dates[n_dates]}\n",
              "Required end date: {forecast_end_date}\n",
              "Missing {as.numeric(forecast_end_date - series_dates[n_dates])} days of forecast data."))
  }

  message(glue("  ✓ Sufficient data for {window}-day rolling window"))
  message(glue("  ✓ {label} validation complete!"))
}

# Validate forest timeseries
validate_timeseries(forest_series, "forest", forest_window)

# Validate non-forest timeseries (if different from forest)
if (forest_gridmet_var != non_forest_gridmet_var) {
  validate_timeseries(non_forest_series, "non-forest", non_forest_window)
} else {
  message("Non-forest uses same timeseries as forest - validation already complete")
}

message("All timeseries validation checks passed!")

# ============================================================================
# CALCULATE ROLLING AVERAGES
# ============================================================================

message("Calculating rolling averages...")

# Calculate forest rolling window
forest_data_file <- tempfile(fileext = ".tif")
if (forest_window > 1) {
  message(glue("  Calculating {forest_window}-day rolling average for forest ({forest_variable})"))
  forest_data <- terra::roll(forest_series, n = forest_window, fun = mean, type = "to", circular = FALSE, filename = forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
    subset(time(.) >= today & time(.) <= today + 7)
} else {
  message(glue("  Using current day values for forest ({forest_variable})"))
  forest_data <- forest_series %>% subset(time(.) >= today & time(.) <= today + 7)
}

# Calculate non-forest rolling window
non_forest_data_file <- tempfile(fileext = ".tif")
if (non_forest_window > 1) {
  message(glue("  Calculating {non_forest_window}-day rolling average for non-forest ({non_forest_variable})"))
  non_forest_data <- terra::roll(non_forest_series, n = non_forest_window, fun = mean, type = "to", circular = FALSE, filename = non_forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
    subset(time(.) >= today & time(.) <= today + 7)
} else {
  message(glue("  Using current day values for non-forest ({non_forest_variable})"))
  non_forest_data <- non_forest_series %>% subset(time(.) >= today & time(.) <= today + 7)
}

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

# Calculate optimal dimensions based on ecoregion extent
message("Calculating optimal map dimensions based on ecoregion extent...")
eco_extent <- ext(ecoregion_boundary)
eco_width <- eco_extent$xmax - eco_extent$xmin
eco_height <- eco_extent$ymax - eco_extent$ymin
aspect_ratio <- eco_width / eco_height

message(glue("Ecoregion aspect ratio: {round(aspect_ratio, 2)} (width/height)"))

# For desktop: 4 columns layout, base height of 3 inches per row
# Calculate width to maintain aspect ratio
desktop_base_height <- 3  # inches per facet row
desktop_ncol <- 4
desktop_nrow <- 2  # 8 days / 4 columns = 2 rows
desktop_plot_height <- desktop_base_height * desktop_nrow
desktop_plot_width <- desktop_plot_height * aspect_ratio * (desktop_ncol / desktop_nrow)

# Add padding for legend and margins
desktop_height <- desktop_plot_height + 2  # extra space for legend at bottom
desktop_width <- desktop_plot_width + 0.5  # minimal side padding

message(glue("Desktop dimensions: {round(desktop_width, 1)} x {round(desktop_height, 1)} inches"))

# For mobile: 2 columns layout, taller format
mobile_base_height <- 3.5  # inches per facet row
mobile_ncol <- 2
mobile_nrow <- 4  # 8 days / 2 columns = 4 rows
mobile_plot_height <- mobile_base_height * mobile_nrow
mobile_plot_width <- mobile_plot_height * aspect_ratio * (mobile_ncol / mobile_nrow)

# Add padding
mobile_height <- mobile_plot_height + 2.5  # extra space for legend
mobile_width <- mobile_plot_width + 0.5  # minimal side padding

message(glue("Mobile dimensions: {round(mobile_width, 1)} x {round(mobile_height, 1)} inches"))

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
  labs(
    title = glue("Wildfire Danger Forecast ({variable_display_name})"),
    subtitle = glue("{ecoregion_name} from {today}"),
    fill = "Proportion of Fires"
  ) +
  theme(
    legend.position = "bottom",
    legend.justification = "right",
    legend.box.spacing = unit(0.5, "cm"),
    plot.margin = margin(t = 10, r = 5, b = 10, l = 5, unit = "pt"),
    axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1, size = 12),
    axis.text.y = element_text(size = 12),
    axis.title = element_text(size = 16),
    plot.title = element_text(size = 22, margin = margin(b = 5)),
    plot.subtitle = element_text(size = 18, margin = margin(b = 10)),
    strip.text = element_text(size = 14),
    legend.title = element_text(size = 20, margin = margin(r = 20, b = 20)),
    legend.text = element_text(size = 16),
    legend.key.width = unit(2, "cm"),
    legend.key.height = unit(0.5, "cm")
  )
ggsave(file.path(out_dir, "fire_danger_forecast.png"),
  plot = p_desktop, width = desktop_width, height = desktop_height, dpi = 300
)

# Mobile version
message("Saving mobile version...")
p_mobile <- base_plot +
  facet_wrap(~lyr, ncol = 2) +
  labs(
    title = glue("Wildfire Danger Forecast ({variable_display_name})"),
    subtitle = glue("{ecoregion_name} from {today}"),
    fill = "Proportion of Fires"
  ) +
  theme(
    legend.position = "bottom",
    legend.justification = "right",
    legend.box.spacing = unit(0.5, "cm"),
    plot.margin = margin(t = 10, r = 5, b = 10, l = 5, unit = "pt"),
    axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1, size = 14),
    axis.text.y = element_text(size = 14),
    axis.title = element_text(size = 18),
    plot.title = element_text(size = 24, margin = margin(b = 10)),
    plot.subtitle = element_text(size = 16),
    strip.text = element_text(size = 18),
    legend.title = element_text(size = 18, margin = margin(r = 20, b = 20)),
    legend.text = element_text(size = 18),
    legend.key.width = unit(1.5, "cm"),
    legend.key.height = unit(0.6, "cm")
  )
ggsave(file.path(out_dir, "fire_danger_forecast_mobile.png"),
  plot = p_mobile, width = mobile_width, height = mobile_height, dpi = 300
)

# Trim whitespace from maps using ImageMagick
message("Trimming whitespace from maps...")
desktop_png <- file.path(out_dir, "fire_danger_forecast.png")
mobile_png <- file.path(out_dir, "fire_danger_forecast_mobile.png")

system2("convert", args = c(desktop_png, "-trim", "+repage", "-bordercolor", "white", "-border", "20", desktop_png))
system2("convert", args = c(mobile_png, "-trim", "+repage", "-bordercolor", "white", "-border", "20", mobile_png))

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
