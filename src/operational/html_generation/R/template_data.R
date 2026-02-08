# template_data.R - Data context preparation for HTML templates
#
# Functions to load configuration and prepare data contexts for
# jinjar template rendering.

suppressPackageStartupMessages({
  library(yaml)
  library(glue)
})

#' Get human-readable display name for a variable
#'
#' @param var Character string with variable code (e.g., "vpd", "fm1000inv")
#' @return Character string with human-readable name
get_variable_display_name <- function(var) {
  display_names <- list(
    vpd = "Vapor Pressure Deficit (VPD)",
    fm1000 = "1000-hour Fuel Moisture (FM1000)",
    fm1000inv = "1000-hour Fuel Moisture (FM1000)",
    fm100 = "100-hour Fuel Moisture (FM100)",
    erc = "Energy Release Component (ERC)",
    cwd = "Climatic Water Deficit (CWD)",
    gdd_0 = "Growing Degree Days (GDD\u2080)",
    bi = "Burning Index (BI)"
  )

  if (var %in% names(display_names)) {
    return(display_names[[var]])
  }

  # Default: uppercase the variable name
  toupper(var)
}

#' Check if a variable uses rolling sum (flux) instead of rolling average (state)
#'
#' @param var Character string with variable code
#' @return Logical; TRUE if variable is a flux type
is_flux_variable <- function(var) {
  var %in% c("cwd", "gdd_0")
}

#' Get rolling type description for a variable
#'
#' @param var Character string with variable code
#' @return Character string ("rolling sum" or "rolling average")
get_rolling_type <- function(var) {
  if (is_flux_variable(var)) {
    "rolling sum"
  } else {
    "rolling average"
  }
}

#' Load ecoregion configuration from YAML
#'
#' @param ecoregion Character string with ecoregion name_clean (e.g., "middle_rockies")
#' @param config_path Path to ecoregions.yaml config file
#' @return List with ecoregion configuration
load_ecoregion_config <- function(ecoregion, config_path = "config/ecoregions.yaml") {
  if (!file.exists(config_path)) {
    stop(glue("Config file not found: {config_path}"))
  }

  config <- read_yaml(config_path)

  # Find the matching ecoregion
  eco_idx <- which(sapply(config$ecoregions, function(x) x$name_clean == ecoregion))

  if (length(eco_idx) == 0) {
    stop(glue("Ecoregion '{ecoregion}' not found in config"))
  }

  config$ecoregions[[eco_idx]]
}

#' Get all enabled ecoregions from config
#'
#' @param config_path Path to ecoregions.yaml config file
#' @return List of enabled ecoregion configurations
get_enabled_ecoregions <- function(config_path = "config/ecoregions.yaml") {
  if (!file.exists(config_path)) {
    stop(glue("Config file not found: {config_path}"))
  }

  config <- read_yaml(config_path)

  # Filter to enabled ecoregions
  Filter(function(x) isTRUE(x$enabled), config$ecoregions)
}

#' Prepare methodology table context
#'
#' Builds the data context for the methodology table partial template.
#'
#' @param eco_config Ecoregion configuration list
#' @return List with methodology context data
prepare_methodology_context <- function(eco_config) {
  result <- list(
    has_forest = !is.null(eco_config$cover_types$forest),
    has_non_forest = !is.null(eco_config$cover_types$non_forest)
  )

  if (result$has_forest) {
    forest <- eco_config$cover_types$forest
    result$forest_variable <- get_variable_display_name(forest$variable)
    result$forest_window <- forest$window
    result$forest_roll_type <- get_rolling_type(forest$variable)
  }

  if (result$has_non_forest) {
    non_forest <- eco_config$cover_types$non_forest
    result$non_forest_variable <- get_variable_display_name(non_forest$variable)
    result$non_forest_window <- non_forest$window
    result$non_forest_roll_type <- get_rolling_type(non_forest$variable)
  }

  result
}

#' Map config variable name to forecast data directory name
#'
#' @param var Variable name from config (e.g., "fm1000inv")
#' @return Forecast directory variable name (e.g., "fm1000")
get_forecast_variable <- function(var) {
  # fm1000inv uses fm1000 data
  if (var == "fm1000inv") {
    return("fm1000")
  }
  var
}

#' Check for stale data warnings
#'
#' Checks if STALE_DATA_WARNING.txt exists for the forecast variables
#' used by this ecoregion.
#'
#' @param eco_config Ecoregion configuration list
#' @param data_dir Path to data directory (default: "data")
#' @return List with has_stale_warning boolean and stale_variables string
prepare_stale_warning_context <- function(eco_config, data_dir = "data") {
  stale_vars <- character()

  # Get forecast variables
  forest_var <- NULL
  non_forest_var <- NULL

  if (!is.null(eco_config$cover_types$forest)) {
    forest_var <- get_forecast_variable(eco_config$cover_types$forest$variable)
  }
  if (!is.null(eco_config$cover_types$non_forest)) {
    non_forest_var <- get_forecast_variable(eco_config$cover_types$non_forest$variable)
  }

  # Check if both use the same variable
  same_variable <- !is.null(forest_var) && !is.null(non_forest_var) && forest_var == non_forest_var

  # Check forest variable
  if (!is.null(forest_var)) {
    warning_file <- file.path(data_dir, "forecasts", forest_var, "STALE_DATA_WARNING.txt")
    if (file.exists(warning_file)) {
      if (same_variable) {
        stale_vars <- c(stale_vars, get_variable_display_name(eco_config$cover_types$forest$variable))
      } else {
        stale_vars <- c(stale_vars, paste0(
          get_variable_display_name(eco_config$cover_types$forest$variable),
          " (forest)"
        ))
      }
    }
  }

  # Check non-forest variable (only if different from forest)
  if (!is.null(non_forest_var) && !same_variable) {
    warning_file <- file.path(data_dir, "forecasts", non_forest_var, "STALE_DATA_WARNING.txt")
    if (file.exists(warning_file)) {
      stale_vars <- c(stale_vars, paste0(
        get_variable_display_name(eco_config$cover_types$non_forest$variable),
        " (non-forest)"
      ))
    }
  }

  list(
    has_stale_warning = length(stale_vars) > 0,
    stale_variables = paste(stale_vars, collapse = ", ")
  )
}

#' Check for forecast unavailable warning
#'
#' Checks if FORECAST_UNAVAILABLE_WARNING.txt exists at the ecoregion root level.
#' This file is written when forecast generation fails (e.g., gridMET down, CFSv2
#' unavailable) and cleared on successful completion.
#'
#' @param ecoregion Character string with ecoregion name_clean
#' @param out_dir Path to output directory
#' @return List with has_forecast_warning boolean and forecast_warning_message string
prepare_forecast_warning_context <- function(ecoregion, out_dir = "out/forecasts") {
  warning_file <- file.path(out_dir, ecoregion, "FORECAST_UNAVAILABLE_WARNING.txt")

  if (file.exists(warning_file)) {
    lines <- readLines(warning_file, warn = FALSE)
    return(list(
      has_forecast_warning = TRUE,
      forecast_warning_message = paste(lines, collapse = "\n")
    ))
  }

  list(
    has_forecast_warning = FALSE,
    forecast_warning_message = ""
  )
}

#' Prepare park analysis context for a single park
#'
#' @param park_code Character string with park code (e.g., "YELL")
#' @param forecast_date Date of the forecast
#' @param ecoregion Character string with ecoregion name_clean
#' @param out_dir Path to output directory
#' @return List with park context data for template rendering
prepare_park_context <- function(park_code, forecast_date, ecoregion, out_dir = "out/forecasts") {
  park_dir <- file.path(out_dir, ecoregion, forecast_date, "parks", park_code)

  # Read the park analysis HTML if it exists
  analysis_file <- file.path(park_dir, "fire_danger_analysis.html")
  analysis_html <- ""
  if (file.exists(analysis_file)) {
    analysis_html <- paste(readLines(analysis_file, warn = FALSE), collapse = "\n")
  }

  list(
    park_code = park_code,
    analysis_html = analysis_html,
    has_analysis = nchar(analysis_html) > 0,
    distribution_img = file.path(forecast_date, "parks", park_code, "forecast_distribution.png"),
    threshold_025_img = file.path(forecast_date, "parks", park_code, "threshold_plot_0.25.png"),
    threshold_050_img = file.path(forecast_date, "parks", park_code, "threshold_plot_0.5.png"),
    threshold_075_img = file.path(forecast_date, "parks", park_code, "threshold_plot_0.75.png")
  )
}

#' Prepare the full data context for the main dashboard template
#'
#' @param ecoregion Character string with ecoregion name_clean
#' @param forecast_date Date for the forecast (default: today)
#' @param project_dir Project root directory
#' @return List with complete data context for daily_forecast.jinja2
prepare_dashboard_context <- function(ecoregion,
                                       forecast_date = Sys.Date(),
                                       project_dir = ".") {
  # Load ecoregion config
  config_path <- file.path(project_dir, "config/ecoregions.yaml")
  eco_config <- load_ecoregion_config(ecoregion, config_path)

  # Get all enabled ecoregions for dropdown
  all_ecoregions <- get_enabled_ecoregions(config_path)

  # Determine forecast map date by finding the most recent date directory
  # that contains a forecast map. This handles multi-day outages gracefully.
  today <- as.character(forecast_date)
  out_dir <- file.path(project_dir, "out/forecasts")
  ecoregion_dir <- file.path(out_dir, ecoregion)

  map_date <- NULL
  if (dir.exists(ecoregion_dir)) {
    date_dirs <- list.dirs(ecoregion_dir, recursive = FALSE, full.names = FALSE)
    date_dirs <- sort(date_dirs[grepl("^\\d{4}-\\d{2}-\\d{2}$", date_dirs)], decreasing = TRUE)
    for (d in date_dirs) {
      if (file.exists(file.path(ecoregion_dir, d, "fire_danger_forecast.png"))) {
        map_date <- d
        break
      }
    }
  }
  if (is.null(map_date)) {
    map_date <- today
    message("No existing forecast map found in any date directory")
  } else if (map_date != today) {
    message(glue("Using forecast from {map_date} (today's not available)"))
  }

  # Prepare park contexts
  parks <- eco_config$parks
  if (is.null(parks)) parks <- character()

  park_contexts <- lapply(seq_along(parks), function(i) {
    ctx <- prepare_park_context(parks[i], map_date, ecoregion, out_dir)
    ctx$is_first <- (i == 1)
    ctx
  })

  # Build the full context
  list(
    display_date = today,
    ecoregion = ecoregion,
    ecoregion_name = eco_config$name,

    forecast_map_date = map_date,
    forecast_map_path = file.path(map_date, "fire_danger_forecast.png"),
    forecast_map_mobile_path = file.path(map_date, "fire_danger_forecast_mobile.png"),

    ecoregions = lapply(all_ecoregions, function(eco) {
      list(
        name_clean = eco$name_clean,
        name = eco$name,
        is_current = eco$name_clean == ecoregion
      )
    }),

    methodology = prepare_methodology_context(eco_config),

    stale_warning = prepare_stale_warning_context(
      eco_config,
      file.path(project_dir, "data")
    ),

    forecast_warning = prepare_forecast_warning_context(
      ecoregion,
      file.path(project_dir, "out/forecasts")
    ),

    parks = park_contexts,
    has_parks = length(park_contexts) > 0
  )
}

#' Prepare data context for the index landing page
#'
#' @param project_dir Project root directory
#' @return List with data context for index.jinja2
prepare_index_context <- function(project_dir = ".") {
  config_path <- file.path(project_dir, "config/ecoregions.yaml")
  enabled <- get_enabled_ecoregions(config_path)

  list(
    today = as.character(Sys.Date()),
    ecoregions = lapply(enabled, function(eco) {
      list(
        name_clean = eco$name_clean,
        name = eco$name
      )
    })
  )
}

#' Prepare data context for park analysis HTML snippet
#'
#' @param park_name Full park name
#' @param park_stats List with park statistics (extreme_pct, very_high_pct, etc.)
#' @param status List with overall status (emoji, label, color)
#' @param coverage_pct Percentage of park within ecoregion (optional)
#' @param ecoregion_name Name of the ecoregion (optional)
#' @param park_area_clipped_km2 Area of park within ecoregion in km^2 (optional)
#' @param park_area_total_km2 Total park area in km^2 (optional)
#' @return List with data context for park_analysis.jinja2
prepare_park_analysis_context <- function(park_name,
                                           park_stats,
                                           status,
                                           coverage_pct = 100,
                                           ecoregion_name = NULL,
                                           park_area_clipped_km2 = NULL,
                                           park_area_total_km2 = NULL) {
  # Build coverage note if needed
  has_coverage_note <- coverage_pct < 99

  # Define danger levels for iteration in template
  danger_levels <- list(
    list(emoji = "\u26AB", label = "Extreme", pct = park_stats$extreme_pct,
         color = "#000", pct_display = sprintf("%.1f", park_stats$extreme_pct)),
    list(emoji = "\U0001F534", label = "Very High", pct = park_stats$very_high_pct,
         color = "#E74C3C", pct_display = sprintf("%.1f", park_stats$very_high_pct)),
    list(emoji = "\U0001F7E0", label = "High", pct = park_stats$high_pct,
         color = "#E67E22", pct_display = sprintf("%.1f", park_stats$high_pct)),
    list(emoji = "\U0001F7E1", label = "Elevated", pct = park_stats$elevated_pct,
         color = "#F39C12", pct_display = sprintf("%.1f", park_stats$elevated_pct)),
    list(emoji = "\U0001F7E2", label = "Normal", pct = park_stats$normal_pct,
         color = "#27AE60", pct_display = sprintf("%.1f", park_stats$normal_pct))
  )

  list(
    park_name = park_name,
    has_coverage_note = has_coverage_note,
    coverage_pct = sprintf("%.0f", coverage_pct),
    ecoregion_name = ecoregion_name,
    park_area_clipped_km2 = if (!is.null(park_area_clipped_km2)) sprintf("%.1f", park_area_clipped_km2) else NULL,
    park_area_total_km2 = if (!is.null(park_area_total_km2)) sprintf("%.1f", park_area_total_km2) else NULL,
    status_color = status$color,
    status_emoji = status$emoji,
    status_label = status$label,
    max_danger = sprintf("%.2f", park_stats$max_danger),
    median_danger = sprintf("%.2f", park_stats$median_danger),
    danger_levels = danger_levels
  )
}
