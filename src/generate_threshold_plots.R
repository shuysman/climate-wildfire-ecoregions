library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(here)

# Hardcoded thresholds
thresholds <- c(0.25, 0.5, 0.75)

# Load fire danger raster
today <- today()
forecast_file <- here("out", "forecasts", glue("fire_danger_forecast_{today}.nc"))

if (!file.exists(forecast_file)) {
  stop("Forecast file not found at: ", forecast_file)
}

fire_danger_rast <- rast(forecast_file)

# Get today's fire danger (first layer)
fire_danger_today <- fire_danger_rast[[1]]

# Load NPS boundaries and find parks in the Middle Rockies
middle_rockies <- vect(here("data", "us_eco_l3", "us_eco_l3.shp")) %>%
  filter(US_L3NAME == "Middle Rockies") %>%
  project(crs(fire_danger_rast))

nps_boundaries <- vect(here("data", "nps_boundary", "nps_boundary.shp")) %>%
  project(crs(fire_danger_rast))

# First, find parks that intersect with the ecoregion to reduce the search space
intersecting_parks <- nps_boundaries[middle_rockies, ]

# Now, find which of those are completely within the ecoregion
# The result is a matrix where rows are parks and cols are ecoregion polygons
within_matrix <- relate(intersecting_parks, middle_rockies, "within")

# A park is within if it's within ANY of the ecoregion polygons.
# We check this by seeing if the sum of TRUEs for each row is > 0.
is_within <- rowSums(within_matrix, na.rm = TRUE) > 0

# Filter to get only the parks that are fully contained
parks_in_ecoregion <- intersecting_parks[is_within, ]

park_codes <- parks_in_ecoregion$UNIT_CODE

message(paste("Found parks:", paste(park_codes, collapse = ", ")))

# Loop through each park
park_stats_list <- list()

for (park_code in park_codes) {
  park_poly <- parks_in_ecoregion[parks_in_ecoregion$UNIT_CODE == park_code, ]
  park_name <- park_poly$UNIT_NAME

  message(paste("Processing thresholds for:", park_name))

  # Create park-specific output directory
  park_out_dir <- here("out", "forecasts", "parks", park_code)
  dir.create(park_out_dir, showWarnings = FALSE, recursive = TRUE)

  # Crop fire danger raster to the park boundary
  park_fire_danger_rast <- crop(fire_danger_rast, park_poly, mask = TRUE)

  # Calculate fire danger statistics for this park
  park_values <- terra::extract(fire_danger_today, park_poly, fun = NULL)
  fire_danger_values <- park_values[[2]][!is.na(park_values[[2]])]

  if (length(fire_danger_values) > 0) {
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

    park_analysis_html <- paste0(
      "<h3 style='margin: 20px 0 20px 0; padding: 15px; font-size: 1.5em; font-weight: 600; color: #2c3e50; background: #f8f9fa; border-left: 5px solid #3B7A57; border-radius: 4px;'>", park_name, "</h3>",
      "<div style='margin: 0 0 20px 0; padding: 15px; background: #f9f9f9; border-left: 4px solid ", status$color, "; border-radius: 3px;'>",
      "<h4 style='margin: 0 0 10px 0;'>Current Fire Danger Distribution</h4>",
      "<p style='margin: 8px 0; font-size: 0.85em; color: #666; line-height: 1.4;'><em>Categories represent fire danger index ranges: Extreme ≥0.95 | Very High 0.90-0.95 | High 0.75-0.90 | Elevated 0.50-0.75 | Normal <0.50</em></p>",
      "<p style='margin: 8px 0; font-size: 0.95em;'><strong>Overall Status:</strong> ", status$emoji, " ", status$label, "</p>",
      "<p style='margin: 8px 0; font-size: 0.95em;'><strong>Peak Danger:</strong> ", sprintf("%.2f", park_stats$max_danger), " | <strong>Median:</strong> ", sprintf("%.2f", park_stats$median_danger), "</p>",
      "<div style='font-size: 0.9em; margin-top: 12px;'>"
    )

    # Add breakdown bars - always show all levels
    park_analysis_html <- paste0(park_analysis_html,
      "<div style='margin: 5px 0; display: flex; align-items: center;'>",
      "<span style='width: 90px; flex-shrink: 0;'>⚫ Extreme:</span>",
      "<div style='flex-grow: 1; background: #e0e0e0; height: 14px; border-radius: 2px; overflow: hidden;'>",
      "<div style='width: ", park_stats$extreme_pct, "%; background: #000; height: 100%;'></div>",
      "</div>",
      "<span style='margin-left: 8px; width: 50px; text-align: right;'>", sprintf("%.1f", park_stats$extreme_pct), "%</span>",
      "</div>"
    )

    park_analysis_html <- paste0(park_analysis_html,
      "<div style='margin: 5px 0; display: flex; align-items: center;'>",
      "<span style='width: 90px; flex-shrink: 0;'>🔴 Very High:</span>",
      "<div style='flex-grow: 1; background: #e0e0e0; height: 14px; border-radius: 2px; overflow: hidden;'>",
      "<div style='width: ", park_stats$very_high_pct, "%; background: #E74C3C; height: 100%;'></div>",
      "</div>",
      "<span style='margin-left: 8px; width: 50px; text-align: right;'>", sprintf("%.1f", park_stats$very_high_pct), "%</span>",
      "</div>"
    )

    park_analysis_html <- paste0(park_analysis_html,
      "<div style='margin: 5px 0; display: flex; align-items: center;'>",
      "<span style='width: 90px; flex-shrink: 0;'>🟠 High:</span>",
      "<div style='flex-grow: 1; background: #e0e0e0; height: 14px; border-radius: 2px; overflow: hidden;'>",
      "<div style='width: ", park_stats$high_pct, "%; background: #E67E22; height: 100%;'></div>",
      "</div>",
      "<span style='margin-left: 8px; width: 50px; text-align: right;'>", sprintf("%.1f", park_stats$high_pct), "%</span>",
      "</div>"
    )

    park_analysis_html <- paste0(park_analysis_html,
      "<div style='margin: 5px 0; display: flex; align-items: center;'>",
      "<span style='width: 90px; flex-shrink: 0;'>🟡 Elevated:</span>",
      "<div style='flex-grow: 1; background: #e0e0e0; height: 14px; border-radius: 2px; overflow: hidden;'>",
      "<div style='width: ", park_stats$elevated_pct, "%; background: #F39C12; height: 100%;'></div>",
      "</div>",
      "<span style='margin-left: 8px; width: 50px; text-align: right;'>", sprintf("%.1f", park_stats$elevated_pct), "%</span>",
      "</div>"
    )

    park_analysis_html <- paste0(park_analysis_html,
      "<div style='margin: 5px 0; display: flex; align-items: center;'>",
      "<span style='width: 90px; flex-shrink: 0;'>🟢 Normal:</span>",
      "<div style='flex-grow: 1; background: #e0e0e0; height: 14px; border-radius: 2px; overflow: hidden;'>",
      "<div style='width: ", park_stats$normal_pct, "%; background: #27AE60; height: 100%;'></div>",
      "</div>",
      "<span style='margin-left: 8px; width: 50px; text-align: right;'>", sprintf("%.1f", park_stats$normal_pct), "%</span>",
      "</div>"
    )

    park_analysis_html <- paste0(park_analysis_html, "</div></div>")

    # Save park-specific analysis HTML
    writeLines(park_analysis_html, file.path(park_out_dir, "fire_danger_analysis.html"))
  }

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
}

message("Fire danger analysis generation complete.")
