### Generate park-specific fire danger threshold plots
### Accepts ecoregion parameter to process parks within that ecoregion

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(here)
library(yaml)
library(jinjar)

# Source HTML template utilities
source(here("src", "operational", "html_generation", "R", "render_templates.R"))
source(here("src", "operational", "html_generation", "R", "template_data.R"))

# ============================================================================
# CONFIGURATION
# ============================================================================

# Get ecoregion from command line arguments or environment variable
args <- commandArgs(trailingOnly = TRUE)
ecoregion_name_clean <- if (length(args) >= 1) {
  args[1]
} else {
  Sys.getenv("ECOREGION", unset = "middle_rockies")
}

# Optional: accept date parameter for testing (default to today)
forecast_date <- if (length(args) >= 2) {
  as.Date(args[2])
} else {
  today()
}

message(glue("========================================"))
message(glue("Generating park threshold plots for: {ecoregion_name_clean}"))
message(glue("========================================"))

# Load configuration
config <- read_yaml(here("config", "ecoregions.yaml"))

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

ecoregion_name <- ecoregion_config$name
ecoregion_id <- ecoregion_config$id
park_codes <- ecoregion_config$parks

if (is.null(park_codes) || length(park_codes) == 0) {
  message("No parks configured for this ecoregion. Skipping park analysis.")
  quit(save = "no", status = 0)
}

message(glue("Found {length(park_codes)} parks in config: {paste(park_codes, collapse=', ')}"))

# ============================================================================
# LOAD DATA
# ============================================================================

# Hardcoded thresholds
thresholds <- c(0.25, 0.5, 0.75)

# Load fire danger raster from new directory structure
forecast_file <- here("out", "forecasts", ecoregion_name_clean, forecast_date, "fire_danger_forecast.nc")

if (!file.exists(forecast_file)) {
  stop("Forecast file not found at: ", forecast_file)
}

fire_danger_rast <- rast(forecast_file)

# Get today's fire danger (first layer)
fire_danger_today <- fire_danger_rast[[1]]

# Load ecoregion boundary
ecoregion_boundary <- vect(here("data", "us_eco_l3", "us_eco_l3.shp")) %>%
  filter(US_L3NAME == ecoregion_name) %>%
  project(crs(fire_danger_rast))

# Load NPS boundaries
nps_boundaries_path <- here("data", "nps_boundary", "nps_boundary.shp")
if (!file.exists(nps_boundaries_path)) {
  warning("NPS boundaries not found at: ", nps_boundaries_path)
  message("Skipping park analysis.")
  quit(save = "no", status = 0)
}

nps_boundaries <- vect(nps_boundaries_path) %>%
  project(crs(fire_danger_rast))

# ============================================================================
# PROCESS EACH PARK
# ============================================================================

park_stats_list <- list()

for (park_code in park_codes) {
  # Find park in NPS boundaries
  park_poly <- nps_boundaries[nps_boundaries$UNIT_CODE == park_code, ]

  if (length(park_poly) == 0) {
    warning(glue("Park code {park_code} not found in NPS boundaries. Skipping."))
    next
  }

  # Get park name before processing
  park_name <- park_poly$UNIT_NAME[1]

  # Dissolve multiple features into single polygon (some parks have multiple non-contiguous areas)
  if (length(park_poly) > 1) {
    park_poly <- aggregate(park_poly, by = "UNIT_CODE")
  }

  message(glue("Processing thresholds for: {park_name} ({park_code})"))

  # Calculate total park area before clipping (sum in case of multiple features)
  park_area_total_km2 <- sum(expanse(park_poly, unit = "km"))

  # Clip park polygon to ecoregion boundary
  # This ensures we only analyze the portion within this ecoregion
  park_poly_clipped <- tryCatch({
    intersect(park_poly, ecoregion_boundary)
  }, error = function(e) {
    warning(glue("Failed to intersect {park_name} with {ecoregion_name} boundary: {e$message}. Skipping."))
    return(NULL)
  })

  if (is.null(park_poly_clipped) || length(park_poly_clipped) == 0) {
    warning(glue("Park {park_name} does not overlap with {ecoregion_name} boundary. Skipping."))
    next
  }

  # Calculate clipped park area and coverage percentage (sum in case of multiple features)
  park_area_clipped_km2 <- sum(expanse(park_poly_clipped, unit = "km"))
  coverage_pct <- (park_area_clipped_km2 / park_area_total_km2) * 100

  # Use clipped polygon for all subsequent operations
  park_poly <- park_poly_clipped

  # Create park-specific output directory using new structure
  park_out_dir <- here("out", "forecasts", ecoregion_name_clean, forecast_date, "parks", park_code)
  dir.create(park_out_dir, showWarnings = FALSE, recursive = TRUE)

  # Crop fire danger raster to the clipped park boundary (with error handling)
  park_fire_danger_rast <- tryCatch({
    crop(fire_danger_rast, park_poly, mask = TRUE)
  }, error = function(e) {
    warning(glue("Failed to crop fire danger raster for {park_name}: {e$message}. Skipping."))
    return(NULL)
  })

  if (is.null(park_fire_danger_rast)) {
    next
  }

  # Calculate fire danger statistics for this park
  park_values <- terra::extract(fire_danger_today, park_poly, fun = NULL)
  fire_danger_values <- park_values[[2]][!is.na(park_values[[2]])]

  if (length(fire_danger_values) == 0) {
    warning(glue("No fire danger values found for {park_name}. Skipping."))
    next
  }

  total_cells <- length(fire_danger_values)

  park_stats <- list(
    name = park_name,
    code = park_code,
    total_cells = total_cells,
    extreme_pct = sum(fire_danger_values >= 0.95) / total_cells * 100,
    very_high_pct = sum(fire_danger_values >= 0.90 & fire_danger_values < 0.95) / total_cells * 100,
    high_pct = sum(fire_danger_values >= 0.75 & fire_danger_values < 0.90) / total_cells * 100,
    elevated_pct = sum(fire_danger_values >= 0.50 & fire_danger_values < 0.75) / total_cells * 100,
    normal_pct = sum(fire_danger_values < 0.50) / total_cells * 100,
    max_danger = max(fire_danger_values),
    median_danger = median(fire_danger_values)
  )

  park_stats_list[[park_code]] <- park_stats

  # Generate park-specific fire danger analysis HTML
  status <- if (park_stats$extreme_pct > 10) {
    list(label = "EXTREME", emoji = "⚫", color = "#000000")
  } else if (park_stats$very_high_pct > 10 || park_stats$extreme_pct > 0) {
    list(label = "VERY HIGH", emoji = "🔴", color = "#E74C3C")
  } else if (park_stats$high_pct > 10) {
    list(label = "HIGH", emoji = "🟠", color = "#E67E22")
  } else if (park_stats$elevated_pct > 10) {
    list(label = "ELEVATED", emoji = "🟡", color = "#F39C12")
  } else {
    list(label = "NORMAL", emoji = "🟢", color = "#27AE60")
  }

  # Build data context for park analysis template
  park_analysis_context <- prepare_park_analysis_context(
    park_name = park_name,
    park_stats = park_stats,
    status = status,
    coverage_pct = coverage_pct,
    ecoregion_name = ecoregion_name,
    park_area_clipped_km2 = park_area_clipped_km2,
    park_area_total_km2 = park_area_total_km2
  )

  # Render park analysis HTML using jinjar template
  park_analysis_html <- render_partial("park_analysis.jinja2", park_analysis_context)

  # Save park-specific analysis HTML
  writeLines(park_analysis_html, file.path(park_out_dir, "fire_danger_analysis.html"))

  # Loop through thresholds and generate plots for the park
  for (threshold in thresholds) {
    # Threshold the raster
    thresholded_rast <- park_fire_danger_rast >= threshold

    # Calculate the percentage of cells above the threshold for each layer
    percent_above <- global(thresholded_rast, fun = "mean", na.rm = TRUE)

    percent_above$date <- time(park_fire_danger_rast)

    p <- ggplot(percent_above, aes(x = date, y = mean)) +
      geom_col() +
      scale_x_date(date_breaks = "1 day", expand = c(0, 0)) +
      theme(axis.text.x = element_text(angle = 90, vjust = 0.5)) +
      scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
      labs(
        y = "% of Area at or Above Threshold", x = "Date",
        title = glue("Percentage of {park_name} at or Above {threshold} Fire Danger")
      )

    # Save the plot to the park-specific directory
    ggsave(file.path(park_out_dir, glue("threshold_plot_{threshold}.png")), plot = p, height = 4, width = 8)
  }

  # ============================================================================
  # Generate forecast distribution plot (stacked bar chart)
  # ============================================================================

  message(glue("  Generating forecast distribution plot for {park_name}"))

  # Calculate fire danger category distribution for each forecast day
  forecast_dates <- time(park_fire_danger_rast)
  n_days <- length(forecast_dates)

  # Initialize data frame for category distributions
  category_data <- data.frame()

  for (i in 1:n_days) {
    layer <- park_fire_danger_rast[[i]]
    values <- values(layer, mat = FALSE)
    values <- values[!is.na(values)]

    if (length(values) == 0) {
      warning(glue("  Skipping day {i} for {park_name}: no valid values"))
      next
    }

    # Get the date for this layer
    current_date <- forecast_dates[i]

    # Skip if date is NA or invalid
    if (is.na(current_date)) {
      warning(glue("  Skipping day {i} for {park_name}: date is NA"))
      next
    }

    total_cells <- length(values)

    # Calculate percentage in each category
    extreme_pct <- sum(values >= 0.95) / total_cells * 100
    very_high_pct <- sum(values >= 0.90 & values < 0.95) / total_cells * 100
    high_pct <- sum(values >= 0.75 & values < 0.90) / total_cells * 100
    elevated_pct <- sum(values >= 0.50 & values < 0.75) / total_cells * 100
    normal_pct <- sum(values < 0.50) / total_cells * 100

    # Add to data frame
    day_data <- data.frame(
      date = current_date,
      category = c("Normal", "Elevated", "High", "Very High", "Extreme"),
      percentage = c(normal_pct, elevated_pct, high_pct, very_high_pct, extreme_pct),
      stringsAsFactors = FALSE
    )

    category_data <- rbind(category_data, day_data)
  }

  # Remove any rows with NA dates that might have slipped through
  category_data <- category_data[!is.na(category_data$date), ]

  # Check if we have any data to plot
  if (nrow(category_data) == 0) {
    warning(glue("  No valid data for {park_name} forecast distribution plot. Skipping."))
    next
  }

  message(glue("  Processing {length(unique(category_data$date))} days of data for {park_name}"))

  # Check for any NA or invalid percentages
  if (any(is.na(category_data$percentage))) {
    warning(glue("  Found NA percentages in {park_name} data"))
    category_data <- category_data[!is.na(category_data$percentage), ]
  }

  # Check for percentages outside valid range
  if (any(category_data$percentage < 0 | category_data$percentage > 100)) {
    warning(glue("  Found invalid percentages in {park_name}: min={min(category_data$percentage)}, max={max(category_data$percentage)}"))
  }

  # Check that percentages sum to ~100% for each date
  daily_sums <- aggregate(percentage ~ date, data = category_data, FUN = sum)
  if (any(abs(daily_sums$percentage - 100) > 0.1)) {
    problem_dates <- daily_sums$date[abs(daily_sums$percentage - 100) > 0.1]
    problem_sums <- daily_sums$percentage[abs(daily_sums$percentage - 100) > 0.1]
    warning(glue("  Percentages don't sum to 100% for {park_name} on {length(problem_dates)} day(s): {paste(as.character(problem_dates), '=', round(problem_sums, 1), collapse=', ')}"))

    # Print the actual data for problem dates
    for (pd in problem_dates) {
      problem_rows <- category_data[category_data$date == pd, ]
      message(glue("    Date {pd}: {paste(problem_rows$category, '=', round(problem_rows$percentage, 2), collapse=', ')}"))
    }
  }

  # Check that each date has exactly 5 categories
  category_counts <- aggregate(percentage ~ date, data = category_data, FUN = length)
  if (any(category_counts$percentage != 5)) {
    problem_dates <- category_counts$date[category_counts$percentage != 5]
    problem_counts <- category_counts$percentage[category_counts$percentage != 5]
    warning(glue("  Missing categories for {park_name}: {paste(as.character(problem_dates), 'has', problem_counts, 'categories', collapse='; ')}"))
  }

  # Set factor levels for proper ordering in the plot
  category_data$category <- factor(
    category_data$category,
    levels = c("Normal", "Elevated", "High", "Very High", "Extreme")
  )

  # Define colors for each category (matching the HTML colors)
  category_colors <- c(
    "Normal" = "#27AE60",
    "Elevated" = "#F39C12",
    "High" = "#E67E22",
    "Very High" = "#E74C3C",
    "Extreme" = "#000000"
  )

  # Debug: Check for any problematic values before plotting
  if (any(is.nan(category_data$percentage))) {
    warning(glue("  Found NaN values in {park_name} percentages"))
    category_data <- category_data[!is.nan(category_data$percentage), ]
  }

  if (any(is.infinite(category_data$percentage))) {
    warning(glue("  Found Inf values in {park_name} percentages"))
    category_data <- category_data[!is.infinite(category_data$percentage), ]
  }

  # Filter out zero values to avoid ggplot stacking issues
  # (ggplot can have problems stacking when many values are exactly 0)
  category_data_plot <- category_data[category_data$percentage > 0, ]

  # Sort by date and category to ensure proper stacking order
  category_data_plot <- category_data_plot[order(category_data_plot$date, category_data_plot$category), ]

  # Create stacked bar plot
  p_dist <- ggplot(category_data_plot, aes(x = date, y = percentage, fill = category)) +
    geom_col(position = "stack", width = 0.8) +
    scale_fill_manual(values = category_colors, name = "Fire Danger Category") +
    scale_x_date(date_breaks = "1 day", date_labels = "%b %d", expand = c(0, 0)) +
    scale_y_continuous(
      labels = scales::percent_format(scale = 1),
      limits = c(0, 100),
      expand = c(0, 0),
      oob = scales::squish  # Don't remove values at boundaries
    ) +
    theme_minimal() +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1, size = 10),
      axis.text.y = element_text(size = 10),
      legend.position = "bottom",
      legend.title = element_text(size = 11, face = "bold"),
      plot.title = element_text(size = 14, face = "bold", hjust = 0),
      plot.subtitle = element_text(size = 10, color = "#666666", hjust = 0),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_line(color = "#e0e0e0"),
      plot.background = element_rect(fill = "white", color = NA),
      panel.background = element_rect(fill = "white", color = NA),
      legend.background = element_rect(fill = "white", color = NA)
    ) +
    labs(
      y = "Percentage of Park Area",
      x = "Date",
      title = glue("Fire Danger Category Forecast - {park_name}"),
      subtitle = "Distribution of fire danger categories across forecast period"
    )

  # Save the forecast distribution plot
  ggsave(
    file.path(park_out_dir, "forecast_distribution.png"),
    plot = p_dist,
    height = 5,
    width = 10,
    dpi = 150,
    bg = "white"
  )
}

message(glue("Fire danger analysis generation complete for {ecoregion_name_clean}."))
message(glue("Processed {length(park_stats_list)} parks."))
