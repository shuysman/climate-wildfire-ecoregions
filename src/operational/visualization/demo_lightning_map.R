#!/usr/bin/env Rscript
#
# demo_lightning_map.R
#
# Demonstration script for the lightning strike danger visualization system.
# This script generates a sample lightning map with mock data to showcase
# the system without requiring Weatherbit API credentials.
#
# Usage:
#   Rscript demo_lightning_map.R [ecoregion_name_clean] [n_strikes] [output_dir]
#
# Examples:
#   Rscript demo_lightning_map.R                      # Uses middle_rockies, 50 strikes
#   Rscript demo_lightning_map.R middle_rockies 100   # 100 mock strikes
#   Rscript demo_lightning_map.R southern_rockies 75 /tmp/demo
#
# The script will:
#   1. Load fire danger raster data (if available) or create synthetic data
#   2. Generate mock lightning strikes within the ecoregion boundary
#   3. Create an interactive Leaflet map showing:
#      - Fire danger layer with opacity control
#      - NPS park boundaries
#      - Lightning strike markers colored by fire danger
#      - Collapsible info panel with strike details
#   4. Save the map as a self-contained HTML file
#

library(terra)
library(tidyverse)
library(tidyterra)
library(glue)
library(here)
library(leaflet)
library(viridisLite)
library(htmlwidgets)
library(htmltools)
library(yaml)

# Parse command line arguments
cmd_args <- commandArgs(trailingOnly = TRUE)
ecoregion_name_clean <- if (length(cmd_args) >= 1) cmd_args[1] else "middle_rockies"
n_strikes <- if (length(cmd_args) >= 2) as.integer(cmd_args[2]) else 50
output_dir <- if (length(cmd_args) >= 3) cmd_args[3] else here("out", "demo")
# High danger mode: "high", "extreme", or "normal" (default)
danger_mode <- if (length(cmd_args) >= 4) tolower(cmd_args[4]) else "high"

# Ensure output directory exists
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

message(glue("=== Lightning Map Demo ==="))
message(glue("Ecoregion: {ecoregion_name_clean}"))
message(glue("Number of mock strikes: {n_strikes}"))
message(glue("Danger mode: {danger_mode}"))
message(glue("Output directory: {output_dir}"))

# Load ecoregion configuration
config <- read_yaml(here("config", "ecoregions.yaml"))

# Find the ecoregion config
ecoregion_config <- NULL
for (eco in config$ecoregions) {
  if (eco$name_clean == ecoregion_name_clean) {
    ecoregion_config <- eco
    break
  }
}

if (is.null(ecoregion_config)) {
  stop(glue("Ecoregion '{ecoregion_name_clean}' not found in config/ecoregions.yaml"))
}

ecoregion_name <- ecoregion_config$name
ecoregion_id <- ecoregion_config$id
park_codes <- ecoregion_config$parks

message(glue("Found ecoregion: {ecoregion_name} (ID: {ecoregion_id})"))

# Look for existing fire danger data, or create synthetic data
forecast_date <- Sys.Date()
forecast_date_str <- format(forecast_date, "%Y-%m-%d")

# Search for any existing fire danger tif files in the ecoregion forecast directory
forecast_dir <- here("out", "forecasts", ecoregion_name_clean)
cog_file <- NULL

if (dir.exists(forecast_dir)) {
  # Find all fire_danger.tif files and use the most recent one
  tif_files <- list.files(
    forecast_dir,
    pattern = "fire_danger\\.tif$",
    full.names = TRUE,
    recursive = TRUE
  )

  if (length(tif_files) > 0) {
    # Sort by modification time, most recent first
    tif_files <- tif_files[order(file.mtime(tif_files), decreasing = TRUE)]
    cog_file <- tif_files[1]
    message(glue("Found existing fire danger raster: {cog_file}"))
  }
}

# Load or create fire danger raster
if (!is.null(cog_file)) {
  fire_danger <- rast(cog_file)
  # Use first layer if multi-layer
  if (nlyr(fire_danger) > 1) {
    fire_danger <- fire_danger[[1]]
  }
  fire_danger <- aggregate(fire_danger, fact = 2)  # Reduce resolution for faster rendering
} else {
  message("No existing fire danger data found. Creating synthetic demonstration data...")

  # Create synthetic fire danger raster using predetermined bounding boxes
  # This avoids loading the large ecoregion shapefile
  ecoregion_bounds <- list(
    middle_rockies = list(xmin = -115.5, xmax = -104.0, ymin = 42.5, ymax = 49.0),
    southern_rockies = list(xmin = -108.5, xmax = -104.5, ymin = 35.0, ymax = 41.0),
    colorado_plateaus = list(xmin = -114.0, xmax = -106.5, ymin = 34.5, ymax = 42.0),
    mojave_basin_and_range = list(xmin = -118.0, xmax = -113.0, ymin = 34.0, ymax = 38.0)
  )

  if (ecoregion_name_clean %in% names(ecoregion_bounds)) {
    bounds <- ecoregion_bounds[[ecoregion_name_clean]]
  } else {
    # Default fallback - US western region
    bounds <- list(xmin = -115.0, xmax = -105.0, ymin = 40.0, ymax = 48.0)
    message(glue("Using default bounds for unknown ecoregion '{ecoregion_name_clean}'"))
  }

  # Create synthetic fire danger raster at coarse resolution (~10km)
  fire_danger <- rast(
    xmin = bounds$xmin, xmax = bounds$xmax,
    ymin = bounds$ymin, ymax = bounds$ymax,
    resolution = 0.1,
    crs = "EPSG:4326"
  )

  # Generate synthetic fire danger values with spatial gradient
  set.seed(42)  # Reproducible demo
  ncells <- ncell(fire_danger)

  # Create base gradient (higher danger in south/center with some variation)
  coords <- crds(fire_danger)
  lat_range <- bounds$ymax - bounds$ymin
  lon_range <- bounds$xmax - bounds$xmin
  lat_norm <- (coords[, 2] - bounds$ymin) / lat_range
  lon_norm <- (coords[, 1] - bounds$xmin) / lon_range

  # Combine gradients with noise for realistic pattern
  base_danger <- 0.5 - 0.25 * lat_norm + 0.15 * sin(lon_norm * 2 * pi)
  noise <- rnorm(ncells, 0, 0.12)
  danger_values <- pmax(0, pmin(1, base_danger + noise))

  values(fire_danger) <- danger_values

  message("Created synthetic fire danger raster")
}

# Apply danger mode transformation to simulate different fire conditions
# This artificially shifts the fire danger distribution for demo purposes
if (danger_mode == "extreme") {
  # Extreme: shift all values dramatically upward (90th percentile becomes baseline)
  message("Applying EXTREME danger transformation...")
  vals <- values(fire_danger)
  vals <- 0.85 + 0.15 * vals  # Range becomes 0.85-1.0
  vals <- pmin(1, vals)
  values(fire_danger) <- vals
  danger_label <- "EXTREME Fire Danger (Simulated)"
} else if (danger_mode == "high") {
  # High: shift values upward to simulate a high danger day
  message("Applying HIGH danger transformation...")
  vals <- values(fire_danger)
  # Power transformation to push values higher while maintaining some variation
  vals <- vals^0.4  # Compress low values, expand high values
  vals <- 0.3 + 0.7 * vals  # Shift baseline up to 0.3, max at 1.0
  vals <- pmin(1, vals)
  values(fire_danger) <- vals
  danger_label <- "HIGH Fire Danger (Simulated)"
} else if (danger_mode == "moderate") {
  # Moderate: slight upward shift
  message("Applying MODERATE danger transformation...")
  vals <- values(fire_danger)
  vals <- 0.15 + 0.85 * vals
  values(fire_danger) <- vals
  danger_label <- "MODERATE Fire Danger (Simulated)"
} else {
  # Normal: no transformation
  danger_label <- "Fire Danger (Actual Data)"
}

# Try to load ecoregion boundary (optional - for display purposes only)
ecoregion_boundary_file <- here("data", "us_eco_l3", "us_eco_l3.shp")
ecoregion_boundary <- NULL

if (file.exists(ecoregion_boundary_file)) {
  tryCatch({
    ecoregion_boundary <- vect(ecoregion_boundary_file) %>%
      filter(US_L3NAME == ecoregion_name)
    if (nrow(ecoregion_boundary) == 0) {
      ecoregion_boundary <- NULL
      message("Ecoregion boundary not found in shapefile, continuing without it")
    }
  }, error = function(e) {
    message(glue("Could not load ecoregion boundary: {e$message}"))
    ecoregion_boundary <<- NULL
  })
} else {
  message("Ecoregion boundary shapefile not found, continuing without it")
}

# Load NPS boundaries
nps_boundary_file <- here("data", "nps_boundary", "nps_boundary.shp")
if (file.exists(nps_boundary_file)) {
  nps_boundaries <- vect(nps_boundary_file) %>%
    project(crs(fire_danger))

  # Filter parks to only those configured for this ecoregion
  if (!is.null(park_codes) && length(park_codes) > 0) {
    parks_in_config <- nps_boundaries[nps_boundaries$UNIT_CODE %in% park_codes, ]
  } else {
    parks_in_config <- vect()
  }

  # Filter to parks with data coverage
  parks_with_data <- vect()
  if (nrow(parks_in_config) > 0) {
    for (i in 1:nrow(parks_in_config)) {
      park <- parks_in_config[i, ]
      park_values <- terra::extract(fire_danger, park, fun = NULL)
      if (any(!is.na(park_values[[2]]))) {
        parks_with_data <- rbind(parks_with_data, park)
      }
    }
  }
  intersecting_parks <- parks_with_data
} else {
  message("NPS boundary file not found. Parks will not be displayed.")
  intersecting_parks <- vect()
}

# Generate mock lightning data within the raster extent
message(glue("Generating {n_strikes} mock lightning strikes..."))

# Get extent of valid (non-NA) fire danger values
valid_mask <- !is.na(fire_danger)
valid_cells <- which(values(valid_mask))

if (length(valid_cells) < n_strikes) {
  n_strikes <- length(valid_cells)
  message(glue("Reduced to {n_strikes} strikes (limited by raster extent)"))
}

# Sample random cells and get their coordinates
set.seed(123)  # Reproducible demo
sample_cells <- sample(valid_cells, n_strikes)
sample_coords <- xyFromCell(fire_danger, sample_cells)

# Add small random offset for realistic distribution
sample_coords[, 1] <- sample_coords[, 1] + runif(n_strikes, -0.005, 0.005)
sample_coords[, 2] <- sample_coords[, 2] + runif(n_strikes, -0.005, 0.005)

# Generate mock timestamps (past 24 hours)
base_time <- as.POSIXct(paste(forecast_date_str, "12:00:00"), tz = "UTC")
mock_timestamps <- base_time - runif(n_strikes, 0, 86400)  # Random within 24 hours
mock_timestamps_str <- format(mock_timestamps, "%Y-%m-%d %H:%M:%S")

# Create mock lightning data frame
lightning_data <- data.frame(
  lat = sample_coords[, 2],
  lon = sample_coords[, 1],
  timestamp_utc = mock_timestamps_str,
  stringsAsFactors = FALSE
)

message(glue("Generated {nrow(lightning_data)} mock lightning strikes"))

# Extract fire danger values at lightning strike locations
lightning_vect <- vect(lightning_data, geom = c("lon", "lat"), crs = "EPSG:4326")
if (crs(lightning_vect) != crs(fire_danger)) {
  lightning_vect <- project(lightning_vect, crs(fire_danger))
}
fire_danger_values <- terra::extract(fire_danger, lightning_vect)

# Filter strikes outside valid fire danger area
valid_strikes_idx <- !is.na(fire_danger_values[, 2])
filtered_lightning_data <- lightning_data[valid_strikes_idx, ]
filtered_fire_danger_values <- fire_danger_values[valid_strikes_idx, ]

message(glue("{nrow(filtered_lightning_data)} strikes within valid fire danger area"))

# Create color palette
pal <- colorNumeric(
  viridisLite::viridis(256, option = "B"),
  domain = c(0, 1),
  na.color = "transparent"
)

# Park styling - bright green for visibility against purple/red raster
park_line_color <- "#00FF7F"  # Spring green - bright and contrasting
park_fill_color <- "transparent"
park_line_weight <- 4  # Thicker for visibility
park_fill_opacity <- 0.1

# Create leaflet map
m <- leaflet() %>%
  addProviderTiles(providers$CartoDB.Positron) %>%
  addRasterImage(
    fire_danger,
    colors = pal,
    opacity = 0.8,
    project = TRUE,
    maxBytes = 64 * 1024 * 1024,
    group = "Fire Danger",
    layerId = "fire_danger_raster"
  ) %>%
  addLegend(
    pal = pal,
    values = c(0, 1),
    title = "Fire Danger",
    position = "bottomright"
  ) %>%
  addLayersControl(
    overlayGroups = c("Fire Danger", "NPS Boundaries", "Lightning Strikes"),
    options = layersControlOptions(collapsed = TRUE)
  ) %>%
  fitBounds(
    ext(fire_danger)$xmin[[1]],
    ext(fire_danger)$ymin[[1]],
    ext(fire_danger)$xmax[[1]],
    ext(fire_danger)$ymax[[1]]
  )

# Add park boundaries if available
if (nrow(intersecting_parks) > 0) {
  m <- m %>%
    addPolygons(
      data = intersecting_parks,
      color = park_line_color,
      weight = park_line_weight,
      fillColor = park_fill_color,
      fillOpacity = park_fill_opacity,
      popup = ~UNIT_NAME,
      group = "NPS Boundaries"
    )
}

# Add lightning strikes with enhanced visibility
if (nrow(filtered_lightning_data) > 0) {
  # Use a warm palette (yellow -> orange -> red) that contrasts with the viridis background
  lightning_color_func <- function(danger_value) {
    if (is.na(danger_value)) return("#FFFF00")
    if (danger_value < 0.5) {
      # Yellow to orange (0.0-0.5)
      r <- 255
      g <- round(255 - (danger_value * 2) * 105)  # 255 -> 150
      b <- 0
    } else {
      # Orange to red (0.5-1.0)
      r <- 255
      g <- round(150 - ((danger_value - 0.5) * 2) * 150)  # 150 -> 0
      b <- 0
    }
    sprintf("#%02X%02X%02X", r, g, b)
  }

  # Calculate colors for all strikes
  marker_colors <- sapply(filtered_fire_danger_values[, 2], lightning_color_func)

  # Create popup content for each strike
  popup_content <- sapply(1:nrow(filtered_lightning_data), function(i) {
    danger_val <- filtered_fire_danger_values[i, 2]
    fill_color <- marker_colors[i]
    paste0(
      "<div style='min-width: 200px; font-family: sans-serif;'>",
      "<div style='background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: white; padding: 8px 12px; margin: -8px -12px 8px -12px; border-radius: 4px 4px 0 0;'>",
      "<strong style='font-size: 1.1em;'>⚡ Lightning Strike</strong>",
      "</div>",
      "<table style='width: 100%; border-collapse: collapse;'>",
      "<tr><td style='padding: 4px 0; color: #666;'>Time:</td><td style='padding: 4px 0;'>", filtered_lightning_data$timestamp_utc[i], "</td></tr>",
      "<tr><td style='padding: 4px 0; color: #666;'>Location:</td><td style='padding: 4px 0;'>", round(filtered_lightning_data$lat[i], 4), ", ", round(filtered_lightning_data$lon[i], 4), "</td></tr>",
      "<tr><td style='padding: 4px 0; color: #666;'>Fire Danger:</td><td style='padding: 4px 0;'><span style='background: ", fill_color, "; color: #000; padding: 2px 8px; border-radius: 3px; font-weight: bold;'>", round(danger_val, 3), "</span></td></tr>",
      "</table>",
      "</div>"
    )
  })

  # Add outer glow circle (larger, semi-transparent) for visibility
  m <- m %>%
    addCircleMarkers(
      data = filtered_lightning_data,
      lng = ~lon,
      lat = ~lat,
      color = "#000000",
      fillColor = marker_colors,
      radius = 14,
      stroke = TRUE,
      weight = 3,
      opacity = 0.9,
      fillOpacity = 0.3,
      group = "Lightning Strikes"
    )

  # Add inner lightning bolt marker (smaller, solid)
  m <- m %>%
    addCircleMarkers(
      data = filtered_lightning_data,
      lng = ~lon,
      lat = ~lat,
      popup = popup_content,
      color = "#000000",
      fillColor = marker_colors,
      radius = 8,
      stroke = TRUE,
      weight = 2,
      opacity = 1,
      fillOpacity = 1,
      group = "Lightning Strikes"
    )

  # Add a pulsing effect label with lightning emoji at center
  for (i in 1:nrow(filtered_lightning_data)) {
    m <- m %>%
      addLabelOnlyMarkers(
        lng = filtered_lightning_data$lon[i],
        lat = filtered_lightning_data$lat[i],
        label = HTML("<span style='font-size: 16px; text-shadow: 0 0 4px #000, 0 0 8px #fff;'>⚡</span>"),
        labelOptions = labelOptions(
          noHide = TRUE,
          direction = "center",
          textOnly = TRUE,
          style = list(
            "background" = "transparent",
            "border" = "none",
            "font-size" = "16px"
          )
        ),
        group = "Lightning Strikes"
      )
  }
}

# Build info panel content
header_title <- "<h3 style='margin: 0 0 10px 0;'>Lightning Strikes (Demo)</h3>"
update_time <- paste("<p style='margin: 5px 0; font-size: 0.9em;'><strong>Generated:</strong>", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "</p>")

demo_notice <- paste0(
  "<div style='margin: 10px 0; padding: 8px; background: #d4edda; border-left: 3px solid #28a745; color: #155724; font-size: 0.85em;'>",
  "<strong>Demo Mode:</strong> This map shows simulated lightning data for demonstration purposes. ",
  "In production, real-time lightning data is fetched from the Weatherbit API.",
  "</div>"
)

# Create lightning table
if (nrow(filtered_lightning_data) > 0) {
  lightning_table_data <- data.frame(
    Latitude = filtered_lightning_data$lat,
    Longitude = filtered_lightning_data$lon,
    Timestamp = filtered_lightning_data$timestamp_utc,
    Fire_Danger = round(filtered_fire_danger_values[, 2], 2)
  )

  # Sort by fire danger (highest first)
  lightning_table_data <- lightning_table_data[order(-lightning_table_data$Fire_Danger), ]

  lightning_table_html <- paste(
    "<table style='width: 100%; border-collapse: collapse; font-size: 0.85em; margin-top: 10px;'>",
    "<thead><tr style='background: #f0f0f0;'>",
    "<th style='padding: 5px; border: 1px solid #ddd;'>Lat</th>",
    "<th style='padding: 5px; border: 1px solid #ddd;'>Lon</th>",
    "<th style='padding: 5px; border: 1px solid #ddd;'>Time (UTC)</th>",
    "<th style='padding: 5px; border: 1px solid #ddd;'>Danger</th>",
    "</tr></thead>",
    "<tbody>",
    paste(apply(lightning_table_data, 1, function(row) {
      danger_val <- as.numeric(row["Fire_Danger"])
      bg_color <- if (danger_val >= 0.9) "#ffcccc" else if (danger_val >= 0.75) "#fff3cd" else "#ffffff"
      paste0(
        "<tr style='background: ", bg_color, ";'>",
        "<td style='padding: 4px; border: 1px solid #ddd;'>", round(as.numeric(row["Latitude"]), 3), "</td>",
        "<td style='padding: 4px; border: 1px solid #ddd;'>", round(as.numeric(row["Longitude"]), 3), "</td>",
        "<td style='padding: 4px; border: 1px solid #ddd;'>", row["Timestamp"], "</td>",
        "<td style='padding: 4px; border: 1px solid #ddd;'>", row["Fire_Danger"], "</td>",
        "</tr>"
      )
    }), collapse = ""),
    "</tbody></table>"
  )

  lightning_table <- paste0(
    "<div style='max-height: 300px; overflow-y: auto; border: 1px solid #ddd; margin-top: 5px;'>",
    lightning_table_html,
    "</div>"
  )

  # Summary stats
  summary_html <- paste0(
    "<div style='margin: 10px 0; padding: 8px; background: #f8f9fa; border-radius: 4px; font-size: 0.9em;'>",
    "<strong>Summary:</strong> ", nrow(filtered_lightning_data), " strikes | ",
    "Max danger: ", round(max(lightning_table_data$Fire_Danger), 2), " | ",
    "Mean danger: ", round(mean(lightning_table_data$Fire_Danger), 2),
    "</div>"
  )

  header_content <- paste0(header_title, update_time, demo_notice, summary_html, lightning_table)
} else {
  no_strikes_message <- paste0(
    "<div style='margin: 10px 0; padding: 8px; background: #f8f9fa; border-left: 3px solid #6c757d; color: #495057; font-size: 0.9em;'>",
    "No lightning strikes in the demonstration.",
    "</div>"
  )
  header_content <- paste0(header_title, update_time, demo_notice, no_strikes_message)
}

# Add controls to map
m <- m %>%
  addControl(
    html = paste0(
      "<div id='info-panel-container' style='background: white; border-radius: 4px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); max-width: 400px; min-width: 300px;'>",
      "<button id='info-panel-toggle' style='width: 100%; padding: 8px 12px; background: #2c3e50; color: white; border: none; cursor: pointer; font-weight: bold; font-size: 0.9em; text-align: left; border-radius: 4px 4px 0 0; transition: background 0.2s;' onmouseover='this.style.background=\"#34495e\"' onmouseout='this.style.background=\"#2c3e50\"'>",
      "▼ Lightning Info",
      "</button>",
      "<div id='info-panel-content' style='display: block; padding: 12px; max-height: 60vh; overflow-y: auto;'>",
      header_content,
      "</div>",
      "</div>"
    ),
    position = "topleft"
  ) %>%
  addControl(
    html = "<div id='opacity-control' style='padding: 10px; background: white; border-bottom: 1px solid #ccc;'>
    <label for='fire-danger-opacity-slider' style='display: block; margin-bottom: 5px;'>Fire Danger Opacity:</label>
    <input type='range' id='fire-danger-opacity-slider' min='0' max='1' step='0.01' value='0.8'>
  </div>",
    position = "topright"
  ) %>%
  onRender("
    function(el, x) {
      var map = this;
      var slider = document.getElementById('fire-danger-opacity-slider');

      var evthandler = function(e){
        var newOpacity = +e.target.value;

        map.eachLayer(function(layer) {
          if (layer.groupname === 'Fire Danger') {
            if (layer._layers) {
              Object.keys(layer._layers).forEach(function(key) {
                var sublayer = layer._layers[key];
                if (sublayer._container) {
                  sublayer._container.style.opacity = newOpacity;
                }
                if (typeof sublayer.setOpacity === 'function') {
                  sublayer.setOpacity(newOpacity);
                }
              });
            }
          }
        });
      };

      var sliderElement = document.getElementById('fire-danger-opacity-slider');

      sliderElement.addEventListener('mousedown', function() {
        map.dragging.disable();
      });
      sliderElement.addEventListener('mouseup', function() {
        map.dragging.enable();
      });

      sliderElement.addEventListener('touchstart', function(e) {
        map.dragging.disable();
        map.touchZoom.disable();
        map.doubleClickZoom.disable();
        map.scrollWheelZoom.disable();
        e.stopPropagation();
      });
      sliderElement.addEventListener('touchend', function(e) {
        map.dragging.enable();
        map.touchZoom.enable();
        map.doubleClickZoom.enable();
        map.scrollWheelZoom.enable();
        e.stopPropagation();
      });
      sliderElement.addEventListener('touchmove', function(e) {
        e.stopPropagation();
      });

      slider.oninput = evthandler;

      var toggleButton = document.getElementById('info-panel-toggle');
      var panelContent = document.getElementById('info-panel-content');
      var isCollapsed = false;

      toggleButton.addEventListener('click', function() {
        if (isCollapsed) {
          panelContent.style.display = 'block';
          toggleButton.innerHTML = '▼ Lightning Info';
          isCollapsed = false;
        } else {
          panelContent.style.display = 'none';
          toggleButton.innerHTML = '▶ Lightning Info';
          isCollapsed = true;
        }
      });
    }
  ")

# Create banner with danger mode indicator
banner_bg_color <- switch(danger_mode,
  "extreme" = "#dc3545",  # Red
  "high" = "#fd7e14",     # Orange
  "moderate" = "#ffc107", # Yellow
  "#3B7A57"               # Default green
)
banner_text_color <- if (danger_mode %in% c("extreme", "high")) "white" else "#666"

update_notice_banner <- paste0(
  "<div style='background: ", banner_bg_color, "; padding: 10px 15px; border-bottom: 2px solid ", banner_bg_color, "; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'>",
  "<p style='margin: 0; font-size: 0.9em; color: ", banner_text_color, "; text-align: center;'>",
  "<strong>DEMONSTRATION</strong> - ", ecoregion_name, " | ",
  "<strong>", toupper(danger_mode), " FIRE DANGER</strong> (Simulated) | ",
  "Lightning data is synthetic | ",
  "Generated: ", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "</p>",
  "</div>"
)

# Save the widget
output_file <- file.path(output_dir, paste0("lightning_demo_", ecoregion_name_clean, ".html"))
saveWidget(m, output_file, selfcontained = TRUE)

# Add custom CSS for fullscreen layout
html_content <- readLines(output_file)

head_close_idx <- which(grepl("</head>", html_content))[1]
fullscreen_css <- c(
  "<style>",
  "  html, body {",
  "    margin: 0;",
  "    padding: 0;",
  "    height: 100%;",
  "    overflow: hidden;",
  "  }",
  "  #htmlwidget_container {",
  "    height: 100vh !important;",
  "  }",
  "  .leaflet-container {",
  "    height: 100vh !important;",
  "  }",
  "  #update-banner {",
  "    position: fixed;",
  "    top: 0;",
  "    left: 0;",
  "    right: 0;",
  "    z-index: 9999;",
  "  }",
  "  .leaflet-top {",
  "    top: 50px !important;",
  "  }",
  "  #fire-danger-opacity-slider {",
  "    width: 100% !important;",
  "    cursor: pointer;",
  "  }",
  "  @media screen and (max-width: 768px) {",
  "    #opacity-control {",
  "      position: fixed !important;",
  "      bottom: 10px !important;",
  "      left: 10px !important;",
  "      top: auto !important;",
  "      right: auto !important;",
  "      z-index: 1000;",
  "      max-width: 200px;",
  "    }",
  "    .leaflet-top.leaflet-right {",
  "      top: 60px !important;",
  "    }",
  "    #info-panel-container {",
  "      max-width: 90vw !important;",
  "      min-width: 280px !important;",
  "    }",
  "  }",
  "</style>"
)

html_content <- c(
  html_content[1:(head_close_idx - 1)],
  fullscreen_css,
  html_content[head_close_idx:length(html_content)]
)

# Add banner after body tag
body_open_idx <- which(grepl("<body", html_content))[1]
banner_html <- paste0("<div id='update-banner'>", update_notice_banner, "</div>")

html_content <- c(
  html_content[1:body_open_idx],
  banner_html,
  html_content[(body_open_idx + 1):length(html_content)]
)

writeLines(html_content, output_file)

message("")
message(glue("=== Demo Complete ==="))
message(glue("Output saved to: {output_file}"))
message("")
message("To view the demo, open the HTML file in a web browser:")
message(glue("  firefox {output_file}"))
message(glue("  google-chrome {output_file}"))
message(glue("  xdg-open {output_file}"))
message("")
message("The demo shows:")
message("  - Fire danger raster layer (with opacity control)")
message("  - Mock lightning strikes colored by fire danger at impact location")
message("  - NPS park boundaries (if available)")
message("  - Collapsible info panel with strike details")
message("  - Layer toggle controls")
