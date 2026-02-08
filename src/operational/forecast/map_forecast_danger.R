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

# Handle nullable cover types (some ecoregions may only have forest or non-forest)
has_forest <- !is.null(ecoregion_config$cover_types$forest)
has_non_forest <- !is.null(ecoregion_config$cover_types$non_forest)

if (!has_forest && !has_non_forest) {
  stop("Ecoregion must have at least one cover type (forest or non_forest)")
}

forest_window <- if (has_forest) ecoregion_config$cover_types$forest$window else NULL
forest_variable <- if (has_forest) ecoregion_config$cover_types$forest$variable else NULL
forest_gridmet_var <- if (has_forest) ecoregion_config$cover_types$forest$gridmet_varname else NULL

non_forest_window <- if (has_non_forest) ecoregion_config$cover_types$non_forest$window else NULL
non_forest_variable <- if (has_non_forest) ecoregion_config$cover_types$non_forest$variable else NULL
non_forest_gridmet_var <- if (has_non_forest) ecoregion_config$cover_types$non_forest$gridmet_varname else NULL

message(glue("Ecoregion ID: {ecoregion_id}"))
message(glue("Ecoregion Name: {ecoregion_name}"))
message(glue("Cover types present: {paste(c(if(has_forest) 'forest' else NULL, if(has_non_forest) 'non-forest' else NULL), collapse=', ')}"))

# Note: Forest and non-forest can now use different variables
# This supports ecoregions like Canadian Rockies (FM1000 forest, CWD non-forest)
if (has_forest) {
  message(glue("Forest predictor: {forest_variable} ({forest_window}-day window)"))
}
if (has_non_forest) {
  message(glue("Non-forest predictor: {non_forest_variable} ({non_forest_window}-day window)"))
}

# Create display names for title
get_variable_display_name <- function(var) {
  switch(var,
    "vpd" = "VPD",
    "fm1000" = "FM1000",
    "fm1000inv" = "FM1000",
    "fm100" = "FM100",
    "erc" = "ERC",
    "cwd" = "CWD",
    "gdd_0" = "GDD₀",
    toupper(var)  # fallback to uppercase
  )
}

# Determine variable display name for map title
if (has_forest && has_non_forest) {
  forest_display_name <- get_variable_display_name(forest_variable)
  non_forest_display_name <- get_variable_display_name(non_forest_variable)

  if (forest_variable == non_forest_variable) {
    variable_display_name <- forest_display_name
  } else {
    variable_display_name <- glue("{forest_display_name}/{non_forest_display_name}")
  }
} else if (has_forest) {
  variable_display_name <- get_variable_display_name(forest_variable)
} else {
  variable_display_name <- get_variable_display_name(non_forest_variable)
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

message("Loading quantile rasters and eCDF models...")

# Load forest data if present
if (has_forest) {
  forest_quants_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-quants.nc")
  forest_ecdf_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-forest/{ecoregion_id}-{ecoregion_name_clean}-forest-{forest_window}-{toupper(forest_variable)}-ecdf.RDS")

  if (!file.exists(forest_quants_path)) {
    stop(glue("Forest quantile raster not found: {forest_quants_path}"))
  }
  if (!file.exists(forest_ecdf_path)) {
    stop(glue("Forest eCDF model not found: {forest_ecdf_path}"))
  }

  forest_quants_rast <- rast(forest_quants_path)
  forest_fire_danger_ecdf <- readRDS(forest_ecdf_path)
  message("  ✓ Forest quantiles and eCDF loaded")
} else {
  forest_quants_rast <- NULL
  forest_fire_danger_ecdf <- NULL
}

# Load non-forest data if present
if (has_non_forest) {
  non_forest_quants_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-quants.nc")
  non_forest_ecdf_path <- glue("./data/ecdf/{ecoregion_id}-{ecoregion_name_clean}-non_forest/{ecoregion_id}-{ecoregion_name_clean}-non_forest-{non_forest_window}-{toupper(non_forest_variable)}-ecdf.RDS")

  if (!file.exists(non_forest_quants_path)) {
    stop(glue("Non-forest quantile raster not found: {non_forest_quants_path}"))
  }
  if (!file.exists(non_forest_ecdf_path)) {
    stop(glue("Non-forest eCDF model not found: {non_forest_ecdf_path}"))
  }

  non_forest_quants_rast <- rast(non_forest_quants_path)
  non_forest_fire_danger_ecdf <- readRDS(non_forest_ecdf_path)
  message("  ✓ Non-forest quantiles and eCDF loaded")
} else {
  non_forest_quants_rast <- NULL
  non_forest_fire_danger_ecdf <- NULL
}

message("Loading classified cover raster...")
classified_rast_file <- glue("data/classified_cover/ecoregion_{ecoregion_id}_classified.tif")
if (!file.exists(classified_rast_file)) {
  stop(glue("Classified cover file not found: {classified_rast_file}\nPlease run src/01a_pregenerate_cover.R first."))
}
# Note: Even if we only have one cover type model, both cover types may be physically
# present in the ecoregion. We use the classified cover to mask predictions to only
# the cover type we have a model for.

# ============================================================================
# LOAD FORECAST DATA
# ============================================================================

# Function to load forecast for a variable
load_forecast_data <- function(var_name, label, boundary = NULL) {
  message(glue("Loading {var_name} forecast data for {label} areas..."))

  forecast_0_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_0.nc")
  forecast_1_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_1.nc")
  forecast_2_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_2.nc")
  forecast_3_path <- glue("data/forecasts/{var_name}/cfsv2_metdata_forecast_{var_name}_daily_3.nc")

  if (!file.exists(forecast_0_path)) {
    stop(glue("{label} forecast file not found: {forecast_0_path}\nPlease run src/update_all_forecasts.sh first."))
  }

  forecast_0 <- rast(forecast_0_path)
  time(forecast_0) <- as_date(depth(forecast_0), origin = "1900-01-01")

  forecast_1 <- rast(forecast_1_path)
  time(forecast_1) <- as_date(depth(forecast_1), origin = "1900-01-01")

  forecast_2 <- rast(forecast_2_path)
  time(forecast_2) <- as_date(depth(forecast_2), origin = "1900-01-01")

  # f3 is optional - bridges gap when gridMET cache is stale
  forecast_3 <- if (file.exists(forecast_3_path)) {
    f3 <- rast(forecast_3_path)
    time(f3) <- as_date(depth(f3), origin = "1900-01-01")
    f3
  } else {
    message(glue("  Note: {label} forecast file f3 not found (optional). Skipping."))
    NULL
  }

  # Crop to ecoregion extent if boundary provided
  if (!is.null(boundary)) {
    forecast_0 <- crop(forecast_0, boundary)
    forecast_1 <- crop(forecast_1, boundary)
    forecast_2 <- crop(forecast_2, boundary)
    if (!is.null(forecast_3)) forecast_3 <- crop(forecast_3, boundary)
  }

  return(list(f0 = forecast_0, f1 = forecast_1, f2 = forecast_2, f3 = forecast_3))
}

# Determine which forecast variables to load
# GDD_0 requires both tmmx and tmmn
forest_needs_gdd <- has_forest && forest_gridmet_var == "gdd_0"
non_forest_needs_gdd <- has_non_forest && non_forest_gridmet_var == "gdd_0"

# Load forest forecasts (without cropping yet)
if (has_forest) {
  if (forest_needs_gdd) {
    message("Forest uses GDD_0 - loading tmmx and tmmn forecasts...")
    forest_tmax_forecasts <- load_forecast_data("tmmx", "forest (tmax)")
    forest_tmin_forecasts <- load_forecast_data("tmmn", "forest (tmin)")
    # Use tmax as reference for boundary projection
    ecoregion_boundary <- project(ecoregion_boundary, crs(forest_tmax_forecasts$f0))
    # Crop both temperature forecasts
    forest_tmax_forecasts$f0 <- crop(forest_tmax_forecasts$f0, ecoregion_boundary)
    forest_tmax_forecasts$f1 <- crop(forest_tmax_forecasts$f1, ecoregion_boundary)
    forest_tmax_forecasts$f2 <- crop(forest_tmax_forecasts$f2, ecoregion_boundary)
    if (!is.null(forest_tmax_forecasts$f3)) forest_tmax_forecasts$f3 <- crop(forest_tmax_forecasts$f3, ecoregion_boundary)
    forest_tmin_forecasts$f0 <- crop(forest_tmin_forecasts$f0, ecoregion_boundary)
    forest_tmin_forecasts$f1 <- crop(forest_tmin_forecasts$f1, ecoregion_boundary)
    forest_tmin_forecasts$f2 <- crop(forest_tmin_forecasts$f2, ecoregion_boundary)
    if (!is.null(forest_tmin_forecasts$f3)) forest_tmin_forecasts$f3 <- crop(forest_tmin_forecasts$f3, ecoregion_boundary)
  } else {
    forest_forecasts <- load_forecast_data(forest_gridmet_var, "forest")
    # Project ecoregion boundary to forecast CRS
    ecoregion_boundary <- project(ecoregion_boundary, crs(forest_forecasts$f0))
    # Crop the forest forecasts to the projected boundary
    forest_forecasts$f0 <- crop(forest_forecasts$f0, ecoregion_boundary)
    forest_forecasts$f1 <- crop(forest_forecasts$f1, ecoregion_boundary)
    forest_forecasts$f2 <- crop(forest_forecasts$f2, ecoregion_boundary)
    if (!is.null(forest_forecasts$f3)) forest_forecasts$f3 <- crop(forest_forecasts$f3, ecoregion_boundary)
  }
}

# Load non-forest forecasts
if (has_non_forest) {
  if (non_forest_needs_gdd) {
    # Check if we can reuse forest temperature data
    if (forest_needs_gdd) {
      message("Reusing forest temperature forecasts for non-forest GDD_0")
      non_forest_tmax_forecasts <- forest_tmax_forecasts
      non_forest_tmin_forecasts <- forest_tmin_forecasts
    } else {
      message("Non-forest uses GDD_0 - loading tmmx and tmmn forecasts...")
      # Load without cropping first to get CRS for boundary projection
      non_forest_tmax_forecasts <- load_forecast_data("tmmx", "non-forest (tmax)")
      non_forest_tmin_forecasts <- load_forecast_data("tmmn", "non-forest (tmin)")
      # Project boundary if not already done
      if (!has_forest) {
        ecoregion_boundary <- project(ecoregion_boundary, crs(non_forest_tmax_forecasts$f0))
      }
      # Now crop both temperature forecasts
      non_forest_tmax_forecasts$f0 <- crop(non_forest_tmax_forecasts$f0, ecoregion_boundary)
      non_forest_tmax_forecasts$f1 <- crop(non_forest_tmax_forecasts$f1, ecoregion_boundary)
      non_forest_tmax_forecasts$f2 <- crop(non_forest_tmax_forecasts$f2, ecoregion_boundary)
      if (!is.null(non_forest_tmax_forecasts$f3)) non_forest_tmax_forecasts$f3 <- crop(non_forest_tmax_forecasts$f3, ecoregion_boundary)
      non_forest_tmin_forecasts$f0 <- crop(non_forest_tmin_forecasts$f0, ecoregion_boundary)
      non_forest_tmin_forecasts$f1 <- crop(non_forest_tmin_forecasts$f1, ecoregion_boundary)
      non_forest_tmin_forecasts$f2 <- crop(non_forest_tmin_forecasts$f2, ecoregion_boundary)
      if (!is.null(non_forest_tmin_forecasts$f3)) non_forest_tmin_forecasts$f3 <- crop(non_forest_tmin_forecasts$f3, ecoregion_boundary)
    }
  } else if (has_forest && forest_gridmet_var == non_forest_gridmet_var) {
    message("Forest and non-forest use same variable - reusing forecast data")
    non_forest_forecasts <- forest_forecasts
  } else {
    if (!has_forest) {
      # Load without cropping first, then project boundary
      non_forest_forecasts <- load_forecast_data(non_forest_gridmet_var, "non-forest")
      ecoregion_boundary <- project(ecoregion_boundary, crs(non_forest_forecasts$f0))
      non_forest_forecasts$f0 <- crop(non_forest_forecasts$f0, ecoregion_boundary)
      non_forest_forecasts$f1 <- crop(non_forest_forecasts$f1, ecoregion_boundary)
      non_forest_forecasts$f2 <- crop(non_forest_forecasts$f2, ecoregion_boundary)
      if (!is.null(non_forest_forecasts$f3)) non_forest_forecasts$f3 <- crop(non_forest_forecasts$f3, ecoregion_boundary)
    } else {
      # Boundary already projected, can crop directly
      non_forest_forecasts <- load_forecast_data(non_forest_gridmet_var, "non-forest", ecoregion_boundary)
    }
  }
}

# ============================================================================
# RETRIEVE HISTORICAL DATA
# ============================================================================

start_date <- today - 40

# Helper function to validate forecast date, allowing for stale data if warning file exists
check_forecast_date <- function(most_recent_date, var_name, label) {
  # Accept forecasts starting either today or tomorrow
  if (most_recent_date == today + 1 || most_recent_date == today) {
    if (most_recent_date == today) {
      message(glue("Note: {label} forecast starts today ({today}). This is expected for ensemble variables."))
    }
    return(TRUE)
  }

  # Check for stale data warning file
  stale_warning_file <- glue("data/forecasts/{var_name}/STALE_DATA_WARNING.txt")
  if (file.exists(stale_warning_file)) {
    warning(glue("WARNING: Using stale {label} forecast data (starts {most_recent_date}). Stale warning file found."))
    return(TRUE)
  }

  # If no warning file and date is invalid, stop
  stop(glue("{label} forecast date is {most_recent_date} but should be either {today} or {today + 1}. Exiting..."))
}

### Check if most recent forecast is available or raise error
if (has_forest) {
  if (forest_needs_gdd) {
    forest_most_recent <- time(subset(forest_tmax_forecasts$f0, 1))
    # Check both tmax and tmin for stale files? usually they come together. checking tmax/tmmn generic check.
    # checking tmmx implies checking tmmn usually in this pipeline
    check_forecast_date(forest_most_recent, "tmmx", "Forest (tmax)")
  } else {
    forest_most_recent <- time(subset(forest_forecasts$f0, 1))
    check_forecast_date(forest_most_recent, forest_gridmet_var, "Forest")
  }
}

# Check non-forest forecast date if different variable
if (has_non_forest && (!has_forest || forest_gridmet_var != non_forest_gridmet_var)) {
  if (non_forest_needs_gdd) {
    # Only check if we didn't already validate forest temps
    if (!forest_needs_gdd) {
      non_forest_most_recent <- time(subset(non_forest_tmax_forecasts$f0, 1))
      check_forecast_date(non_forest_most_recent, "tmmx", "Non-forest (tmax)")
    }
  } else {
    non_forest_most_recent <- time(subset(non_forest_forecasts$f0, 1))
    check_forecast_date(non_forest_most_recent, non_forest_gridmet_var, "Non-forest")
  }
}

# Define cache directory and gridMET stale warning path
cache_dir <- "./out/cache"
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
gridmet_stale_warning_file <- file.path(out_dir, "GRIDMET_STALE_WARNING.txt")

# Map variable name to gridMET output column name
gridmet_column_map <- list(
  vpd = "daily_mean_vapor_pressure_deficit",
  fm1000 = "dead_fuel_moisture_1000hr",
  cwd = "climatic_water_deficit",
  tmmx = "daily_maximum_temperature",
  tmmn = "daily_minimum_temperature"
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

      # Clear stale warning on successful download
      if (file.exists(gridmet_stale_warning_file)) {
        file.remove(gridmet_stale_warning_file)
      }

      fresh_gridmet
    },
    error = function(e) {
      warning(glue("Failed to retrieve fresh gridMET data: {e$message}"))

      if (file.exists(cache_file)) {
        warning("Using cached gridMET data as a fallback. Data may be stale.")
        cached <- rast(cache_file)
        cache_end <- max(time(cached))
        writeLines(
          c("GRIDMET STALE DATA WARNING",
            "===========================",
            glue("Variable: {var_name}"),
            glue("Generated: {Sys.time()}"),
            glue("GridMET download failed. Using cached data ending {cache_end}."),
            glue("Expected end date: {today - 2}"),
            "Historical data may be stale. Forecast accuracy may be reduced."),
          gridmet_stale_warning_file
        )
        cached
      } else {
        stop("Failed to retrieve gridMET data and no cache file is available. Cannot proceed.")
      }
    }
  )

  return(gridmet_data)
}

# Fetch forest gridMET data
if (has_forest) {
  if (forest_needs_gdd) {
    message("Fetching historical tmmx and tmmn for forest GDD_0 calculation...")
    forest_tmax_gridmet <- fetch_gridmet_data("tmmx", "forest (tmax)", forest_tmax_forecasts$f0)
    forest_tmin_gridmet <- fetch_gridmet_data("tmmn", "forest (tmin)", forest_tmin_forecasts$f0)
  } else {
    forest_gridmet <- fetch_gridmet_data(forest_gridmet_var, "forest", forest_forecasts$f0)
  }
}

# Fetch non-forest gridMET data
if (has_non_forest) {
  if (non_forest_needs_gdd) {
    # Reuse forest temps if available
    if (forest_needs_gdd) {
      message("Reusing gridMET temperature data for non-forest")
      non_forest_tmax_gridmet <- forest_tmax_gridmet
      non_forest_tmin_gridmet <- forest_tmin_gridmet
    } else {
      message("Fetching historical tmmx and tmmn for non-forest GDD_0 calculation...")
      non_forest_tmax_gridmet <- fetch_gridmet_data("tmmx", "non-forest (tmax)", non_forest_tmax_forecasts$f0)
      non_forest_tmin_gridmet <- fetch_gridmet_data("tmmn", "non-forest (tmin)", non_forest_tmin_forecasts$f0)
    }
  } else if (has_forest && forest_gridmet_var == non_forest_gridmet_var) {
    message("Reusing gridMET data for non-forest")
    non_forest_gridmet <- forest_gridmet
  } else {
    non_forest_gridmet <- fetch_gridmet_data(non_forest_gridmet_var, "non-forest", non_forest_forecasts$f0)
  }
}

# ============================================================================
# INFILLING LOGIC - Create full time series
# ============================================================================

# Function to create timeseries by infilling historical data with forecasts
# For regular variables: pass gridmet_data and forecasts
# For GDD_0: pass tmax/tmin gridmet and forecasts separately
create_timeseries <- function(gridmet_data = NULL, forecasts = NULL,
                              tmax_gridmet = NULL, tmax_forecasts = NULL,
                              tmin_gridmet = NULL, tmin_forecasts = NULL,
                              var_name, label) {
  message(glue("Creating {label} timeseries ({var_name})..."))

  # Handle GDD_0 calculation
  if (var_name == "gdd_0") {
    if (is.null(tmax_gridmet) || is.null(tmin_gridmet)) {
      stop("GDD_0 calculation requires tmax_gridmet and tmin_gridmet")
    }

    # Calculate historical GDD_0
    message("  Calculating historical GDD_0 from tmax and tmin...")
    series <- (tmax_gridmet + tmin_gridmet) / 2
    last_date <- max(time(series))
    message(glue("  Last historical date: {last_date}"))

    # Infill with forecast data (oldest first for proper rotation)
    forecast_tmax_list <- c(if (!is.null(tmax_forecasts$f3)) list(tmax_forecasts$f3), list(tmax_forecasts$f2, tmax_forecasts$f1, tmax_forecasts$f0))
    forecast_tmin_list <- c(if (!is.null(tmin_forecasts$f3)) list(tmin_forecasts$f3), list(tmin_forecasts$f2, tmin_forecasts$f1, tmin_forecasts$f0))

    for (i in seq_along(forecast_tmax_list)) {
      tmax_rast <- forecast_tmax_list[[i]]
      tmin_rast <- forecast_tmin_list[[i]]

      new_dates <- time(tmax_rast)[time(tmax_rast) > last_date]
      if (length(new_dates) > 0) {
        message(glue("  Infilling with {length(new_dates)} day(s) from forecast file"))
        infill_tmax <- subset(tmax_rast, time(tmax_rast) %in% new_dates)
        infill_tmin <- subset(tmin_rast, time(tmin_rast) %in% new_dates)
        infill_gdd <- (infill_tmax + infill_tmin) / 2
        series <- c(series, infill_gdd)
        last_date <- max(time(series))
      }
    }
  } else {
    # Regular variable handling
    if (is.null(gridmet_data) || is.null(forecasts)) {
      stop(glue("Regular variable {var_name} requires gridmet_data and forecasts"))
    }

    series <- gridmet_data
    last_date <- max(time(series))
    message(glue("  Last historical date: {last_date}"))

    # Infill with forecast data (f3, f2, f1, f0 in that order - oldest first for proper rotation)
    forecast_list <- c(if (!is.null(forecasts$f3)) list(forecasts$f3), list(forecasts$f2, forecasts$f1, forecasts$f0))
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
  }

  message(glue("  {label} timeseries complete: {min(time(series))} to {max(time(series))}"))
  return(series)
}

# Create forest timeseries
if (has_forest) {
  if (forest_needs_gdd) {
    forest_series <- create_timeseries(
      tmax_gridmet = forest_tmax_gridmet,
      tmax_forecasts = forest_tmax_forecasts,
      tmin_gridmet = forest_tmin_gridmet,
      tmin_forecasts = forest_tmin_forecasts,
      var_name = "gdd_0",
      label = "forest"
    )
  } else {
    forest_series <- create_timeseries(
      gridmet_data = forest_gridmet,
      forecasts = forest_forecasts,
      var_name = forest_gridmet_var,
      label = "forest"
    )
  }
}

# Create non-forest timeseries
if (has_non_forest) {
  if (non_forest_needs_gdd) {
    # Reuse forest series if both use GDD_0
    if (forest_needs_gdd) {
      message("Reusing forest timeseries for non-forest")
      non_forest_series <- forest_series
    } else {
      non_forest_series <- create_timeseries(
        tmax_gridmet = non_forest_tmax_gridmet,
        tmax_forecasts = non_forest_tmax_forecasts,
        tmin_gridmet = non_forest_tmin_gridmet,
        tmin_forecasts = non_forest_tmin_forecasts,
        var_name = "gdd_0",
        label = "non-forest"
      )
    }
  } else if (has_forest && forest_gridmet_var == non_forest_gridmet_var) {
    message("Reusing forest timeseries for non-forest")
    non_forest_series <- forest_series
  } else {
    non_forest_series <- create_timeseries(
      gridmet_data = non_forest_gridmet,
      forecasts = non_forest_forecasts,
      var_name = non_forest_gridmet_var,
      label = "non-forest"
    )
  }
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
if (has_forest) {
  validate_timeseries(forest_series, "forest", forest_window)
}

# Validate non-forest timeseries (if different from forest)
if (has_non_forest) {
  if (!has_forest || forest_gridmet_var != non_forest_gridmet_var) {
    validate_timeseries(non_forest_series, "non-forest", non_forest_window)
  } else {
    message("Non-forest uses same timeseries as forest - validation already complete")
  }
}

message("All timeseries validation checks passed!")

# ============================================================================
# CALCULATE ROLLING AVERAGES
# ============================================================================

message("Calculating rolling windows...")

# Define which variables use SUM (flux variables) vs MEAN (state variables)
# Flux variables accumulate over time (CWD, GDD_0), state variables represent current state (VPD, FM1000)
flux_variables <- c("cwd", "gdd_0")

# Calculate forest rolling window
if (has_forest) {
  forest_data_file <- tempfile(fileext = ".tif")
  if (forest_window > 1) {
    # Determine if this is a flux or state variable
    forest_is_flux <- forest_variable %in% flux_variables
    forest_roll_fun <- if (forest_is_flux) sum else mean
    forest_roll_type <- if (forest_is_flux) "sum" else "average"

    message(glue("  Calculating {forest_window}-day rolling {forest_roll_type} for forest ({forest_variable})"))
    forest_data <- terra::roll(forest_series, n = forest_window, fun = forest_roll_fun, type = "to", circular = FALSE, filename = forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
      subset(time(.) >= today & time(.) <= today + 7)
  } else {
    message(glue("  Using current day values for forest ({forest_variable})"))
    forest_data <- forest_series %>% subset(time(.) >= today & time(.) <= today + 7)
  }
}

# Calculate non-forest rolling window
if (has_non_forest) {
  non_forest_data_file <- tempfile(fileext = ".tif")
  if (non_forest_window > 1) {
    # Determine if this is a flux or state variable
    non_forest_is_flux <- non_forest_variable %in% flux_variables
    non_forest_roll_fun <- if (non_forest_is_flux) sum else mean
    non_forest_roll_type <- if (non_forest_is_flux) "sum" else "average"

    message(glue("  Calculating {non_forest_window}-day rolling {non_forest_roll_type} for non-forest ({non_forest_variable})"))
    non_forest_data <- terra::roll(non_forest_series, n = non_forest_window, fun = non_forest_roll_fun, type = "to", circular = FALSE, filename = non_forest_data_file, wopt = list(gdal = c("COMPRESS=NONE"))) %>%
      subset(time(.) >= today & time(.) <= today + 7)
  } else {
    message(glue("  Using current day values for non-forest ({non_forest_variable})"))
    non_forest_data <- non_forest_series %>% subset(time(.) >= today & time(.) <= today + 7)
  }
}

# Determine dates from whichever cover type is available
dates <- if (has_forest) time(forest_data) else time(non_forest_data)

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
# Project to the CRS of whichever data is available
reference_crs <- if (has_forest) crs(forest_data) else crs(non_forest_data)
classified_rast <- rast(classified_rast_file) %>% project(reference_crs)

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

  combined_layer_file <- tempfile(fileext = ".tif")

  # Handle based on which cover types are available
  if (has_forest && has_non_forest) {
    # Both cover types - combine based on classified cover
    resampled_forest_file <- tempfile(fileext = ".tif")
    resampled_nonforest_file <- tempfile(fileext = ".tif")

    # Get single layer for this day
    forest_layer_lowres <- subset(forest_data, time(forest_data) == day)
    nonforest_layer_lowres <- subset(non_forest_data, time(non_forest_data) == day)

    # Process (binning + ecdf)
    processed_forest <- process_forest_layer(forest_layer_lowres)
    processed_nonforest <- process_non_forest_layer(nonforest_layer_lowres)

    # Resample to high resolution
    resample(processed_forest, classified_rast, filename = resampled_forest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))
    resample(processed_nonforest, classified_rast, filename = resampled_nonforest_file, threads = nthreads, wopt = list(gdal = c("COMPRESS=NONE")))

    # Combine based on cover type (character values: "forest", "non_forest")
    # First combine to temp file, then mask out non-vegetated areas (urban, water, barren, etc.)
    combined_temp_file <- tempfile(fileext = ".tif")
    ifel(classified_rast == "forest", rast(resampled_forest_file), rast(resampled_nonforest_file), filename = combined_temp_file, wopt = list(gdal = c("COMPRESS=NONE")))

    # Mask to valid cover types only (exclude NA pixels which are urban/water/barren/etc.)
    valid_cover_mask <- !is.na(classified_rast)
    mask(rast(combined_temp_file), valid_cover_mask, maskvalues = FALSE, filename = combined_layer_file, wopt = list(gdal = c("COMPRESS=DEFLATE")))

    # Cleanup
    unlink(c(resampled_forest_file, resampled_nonforest_file, combined_temp_file))

  } else if (has_forest) {
    # Forest only - mask to forest pixels
    forest_layer_lowres <- subset(forest_data, time(forest_data) == day)
    processed_forest <- process_forest_layer(forest_layer_lowres)

    # Resample to high resolution
    resampled <- resample(processed_forest, classified_rast, threads = nthreads)

    # Create explicit mask: keep only forest pixels (character value "forest")
    mask_layer <- ifel(classified_rast == "forest", 1, NA)
    mask(resampled, mask_layer, filename = combined_layer_file, wopt = list(gdal = c("COMPRESS=DEFLATE")))

  } else {
    # Non-forest only - mask to non-forest pixels
    nonforest_layer_lowres <- subset(non_forest_data, time(non_forest_data) == day)
    processed_nonforest <- process_non_forest_layer(nonforest_layer_lowres)

    # Resample to high resolution
    resampled <- resample(processed_nonforest, classified_rast, threads = nthreads)

    # Create explicit mask: keep only non-forest pixels (character value "non_forest")
    mask_layer <- ifel(classified_rast == "non_forest", 1, NA)
    mask(resampled, mask_layer, filename = combined_layer_file, wopt = list(gdal = c("COMPRESS=DEFLATE")))
  }

  final_layer_files <- c(final_layer_files, combined_layer_file)

  # Cleanup (gc only, temp files already cleaned up in branches above)
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
# Clean up temp files (only if they exist)
temp_files_to_clean <- c(final_layer_files)
if (has_forest && exists("forest_data_file")) temp_files_to_clean <- c(temp_files_to_clean, forest_data_file)
if (has_non_forest && exists("non_forest_data_file")) temp_files_to_clean <- c(temp_files_to_clean, non_forest_data_file)
unlink(temp_files_to_clean)

message("Forecast generation complete.")

# Calculate and print total runtime
end_time <- Sys.time()
elapsed_time <- end_time - start_time
message(glue("Total script runtime: {format(elapsed_time)}"))
message(glue("Output directory: {out_dir}"))
