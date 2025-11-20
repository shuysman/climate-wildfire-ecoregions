library(terra)
library(ncdf4)
library(tidyverse)
library(tidyterra)
library(maptiles)
library(glue)
library(here)
library(leaflet)
library(jsonlite)
library(viridisLite)
library(htmlwidgets)
library(htmltools)
library(yaml)

# Get command line arguments, using a unique variable name to avoid conflicts
cmd_args <- commandArgs(trailingOnly = TRUE)
if (length(cmd_args) != 4) {
  stop("Usage: Rscript map_lightning.R <cog_file> <forecast_status> <forecast_date> <ecoregion_name_clean>", call. = FALSE)
}

cog_file <- cmd_args[1]
forecast_status <- cmd_args[2]
forecast_date_str <- cmd_args[3]
forecast_date <- as.Date(forecast_date_str)
ecoregion_name_clean <- cmd_args[4]

message(glue("Generating lightning map for ecoregion: {ecoregion_name_clean}"))

# Load ecoregion configuration
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

message(glue("Found ecoregion: {ecoregion_name} (ID: {ecoregion_id})"))

# Load the single-layer COG file
if (!file.exists(cog_file)) {
  stop("COG file not found at: ", cog_file)
}

# The input is now a single-layer raster for today, so no subsetting is needed.
fire_danger_today <- rast(cog_file)
fire_danger_today <- aggregate(fire_danger_today, fact = 2)

# Load ecoregion boundary
ecoregion_boundary <- vect(here("data", "us_eco_l3", "us_eco_l3.shp")) %>%
  filter(US_L3NAME == ecoregion_name)

if (nrow(ecoregion_boundary) == 0) {
  stop(glue("Ecoregion boundary not found for '{ecoregion_name}' in us_eco_l3 shapefile"))
}

# Calculate bounding box for lightning API (in WGS84)
ecoregion_boundary_wgs84 <- project(ecoregion_boundary, "EPSG:4326")
bbox <- ext(ecoregion_boundary_wgs84)
lat_min <- bbox$ymin[[1]]
lat_max <- bbox$ymax[[1]]
lon_min <- bbox$xmin[[1]]
lon_max <- bbox$xmax[[1]]

message(glue("Lightning API bounding box: lat {lat_min} to {lat_max}, lon {lon_min} to {lon_max}"))

# Load NPS boundaries
nps_boundaries <- vect(here("data", "nps_boundary", "nps_boundary.shp")) %>%
  project(crs(fire_danger_today)) # Ensure CRS matches the raster

# Filter parks to only those configured for this ecoregion
if (!is.null(park_codes) && length(park_codes) > 0) {
  parks_in_config <- nps_boundaries[nps_boundaries$UNIT_CODE %in% park_codes, ]
} else {
  # If no parks configured, use empty vector
  parks_in_config <- vect()
}

# Trim raster to the extent of non-NA values
trimmed_raster <- trim(fire_danger_today)

# Filter configured parks to only include those with valid fire danger data (non-NA cells)
parks_with_data <- vect()
if (nrow(parks_in_config) > 0) {
  for (i in 1:nrow(parks_in_config)) {
    park <- parks_in_config[i, ]
    # Extract fire danger values within this park boundary
    park_values <- terra::extract(fire_danger_today, park, fun = NULL)
    # Check if there are any non-NA values
    if (any(!is.na(park_values[[2]]))) {
      parks_with_data <- rbind(parks_with_data, park)
    }
  }
}

# Use the filtered parks for the map
intersecting_parks <- parks_with_data

# Define styling for park boundaries
park_line_color <- "#3B7A57" # NPS green
park_fill_color <- "transparent" # No fill
park_line_weight <- 2
park_fill_opacity <- 0.5

api_key <- NULL
if (Sys.getenv("ENVIRONMENT") != "cloud") {
  message("Running in local mode: Attempting to fetch API key from .weatherbit_api_key file...")
  api_key_file <- here(".weatherbit_api_key")
  if (file.exists(api_key_file)) {
    api_key <- readLines(api_key_file, n = 1)
    message("Successfully loaded API key from local file.")
  } else {
    stop("Local .weatherbit_api_key file not found. Cannot proceed without API key in local mode.")
  }
} else {
  # Securely fetch the API key from AWS Secrets Manager
  api_key <- tryCatch(
    {
      message("Running in cloud mode: Fetching API key from AWS Secrets Manager...")
      secrets_manager <- paws::secretsmanager()
      secret_payload <- secrets_manager$get_secret_value(SecretId = "wildfire-forecast/weatherbit-api-key")
      secret_list <- jsonlite::fromJSON(secret_payload$SecretString)
      secret_list$WEATHERBIT_API_KEY
    },
    error = function(e) {
      stop("Failed to retrieve API key from AWS Secrets Manager. Error: ", e$message)
    }
  )
}

if (is.null(api_key) || api_key == "") {
  stop("API key retrieved from Secrets Manager is null or empty.")
}

# Build lightning API URL using ecoregion bounding box
api_url <- glue("https://api.weatherbit.io/v2.0/history/lightning?lat={lat_min}&lon={lon_min}&end_lat={lat_max}&end_lon={lon_max}&date={forecast_date_str}&key={api_key}")

message(glue("Fetching lightning data from API..."))

lightning_data <- tryCatch(
  {
    fromJSON(api_url)
  },
  error = function(e) {
    message("Error fetching lightning data: ", e$message)
    NULL
  }
)

# Create leaflet map
pal <- colorNumeric(viridisLite::viridis(256, option = "B"),
  domain = c(0, 1),
  na.color = "transparent"
)

m <- leaflet() %>%
  addProviderTiles(providers$CartoDB.Positron) %>%
  addRasterImage(fire_danger_today, colors = pal, opacity = 0.8, project = TRUE, maxBytes = 64 * 1024 * 1024, group = "Fire Danger", layerId = "fire_danger_raster") %>%
  addPolygons(
    data = intersecting_parks,
    color = park_line_color,
    weight = park_line_weight,
    fillColor = park_fill_color,
    fillOpacity = park_fill_opacity,
    popup = ~UNIT_NAME,
    group = "NPS Boundaries"
  ) %>% # Add popup for park name
  addLegend(
    pal = pal, values = c(0, 1),
    title = "Fire Danger",
    position = "bottomright"
  ) %>%
  addLayersControl(
    overlayGroups = c("Fire Danger", "NPS Boundaries"),
    options = layersControlOptions(collapsed = TRUE)
  ) %>%
  fitBounds(ext(fire_danger_today)$xmin[[1]], ext(fire_danger_today)$ymin[[1]], ext(fire_danger_today)$xmax[[1]], ext(fire_danger_today)$ymax[[1]])

# Create HTML for the header (compact version)
header_title <- "<h3 style='margin: 0 0 10px 0;'>Lightning Strikes</h3>"
update_time <- paste("<p style='margin: 5px 0; font-size: 0.9em;'><strong>Updated:</strong>", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "</p>")

# Create a top banner notice (to be added separately outside the info panel)
update_notice_banner <- paste0(
  "<div style='background: white; padding: 10px 15px; border-bottom: 2px solid #3B7A57; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'>",
  "<p style='margin: 0; font-size: 0.9em; color: #666; text-align: center;'><em>Fire danger updates daily at ~10:40 AM MT. Lightning data updates hourly. Last updated: ", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "</em></p>",
  "</div>"
)

# Initialize an empty notice
forecast_notice <- ""

# Create a notice ONLY if the forecast is old
if (forecast_status != "Current") {
  notice_text <- "The latest forecast is not yet available. The fire danger shown is based on older data."
  notice_color <- "#D9534F" # Reddish color for a warning
  forecast_notice <- paste0("<div style='margin: 10px 0; padding: 8px; background: #fff3cd; border-left: 3px solid ", notice_color, "; color: #856404; font-size: 0.85em;'><strong>Notice:</strong> ", notice_text, "</div>")
}

if (!is.null(lightning_data) && !is.null(lightning_data$lightning) && is.data.frame(lightning_data$lightning) && nrow(lightning_data$lightning) > 0) {
  lightning_vect <- vect(lightning_data$lightning, geom = c("lon", "lat"), crs = "EPSG:4326")
  fire_danger_values <- terra::extract(fire_danger_today, lightning_vect)

  # Filter out strikes that are outside the raster's non-NA area
  valid_strikes_idx <- !is.na(fire_danger_values[, 2])
  filtered_lightning_data <- lightning_data$lightning[valid_strikes_idx, ]
  filtered_fire_danger_values <- fire_danger_values[valid_strikes_idx, ]

  if (nrow(filtered_lightning_data) > 0) {
    marker_pal <- colorNumeric(viridisLite::viridis(256, option = "B"), domain = c(0, 1), na.color = "transparent")
    marker_colors <- marker_pal(filtered_fire_danger_values[, 2])

    m <- m %>%
      addCircleMarkers(
        data = filtered_lightning_data, lng = ~lon, lat = ~lat, popup = ~ paste("Time:", timestamp_utc),
        color = marker_colors, radius = 5, stroke = FALSE, fillOpacity = 0.8
      )

    # Create a data frame for the table using only filtered strikes
    lightning_table_data <- data.frame(
      Latitude = filtered_lightning_data$lat,
      Longitude = filtered_lightning_data$lon,
      Timestamp = filtered_lightning_data$timestamp_utc,
      Fire_Danger = round(filtered_fire_danger_values[, 2], 2)
    )

    # Create the HTML table (compact version)
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
        paste("<tr><td style='padding: 4px; border: 1px solid #ddd;'>", round(as.numeric(row["Latitude"]), 3),
              "</td><td style='padding: 4px; border: 1px solid #ddd;'>", round(as.numeric(row["Longitude"]), 3),
              "</td><td style='padding: 4px; border: 1px solid #ddd;'>", row["Timestamp"],
              "</td><td style='padding: 4px; border: 1px solid #ddd;'>", row["Fire_Danger"], "</td></tr>")
      }), collapse = ""),
      "</tbody></table>"
    )

    # Wrap the table in a scrollable div (more compact)
    lightning_table <- paste0(
      "<div style='max-height: 300px; overflow-y: auto; border: 1px solid #ddd; margin-top: 5px;'>",
      lightning_table_html,
      "</div>"
    )

    header_content <- paste0(header_title, update_time, forecast_notice, lightning_table)
  } else {
    no_strikes_message <- paste0("<div style='margin: 10px 0; padding: 8px; background: #f8f9fa; border-left: 3px solid #6c757d; color: #495057; font-size: 0.9em;'>No lightning strikes recorded within the forecast area for ", forecast_date_str, ".</div>")
    header_content <- paste0(header_title, update_time, forecast_notice, no_strikes_message)
  }
} else {
  no_strikes_message <- paste0("<div style='margin: 10px 0; padding: 8px; background: #f8f9fa; border-left: 3px solid #6c757d; color: #495057; font-size: 0.9em;'>No lightning strikes recorded for ", forecast_date_str, ".</div>")
  header_content <- paste0(header_title, update_time, forecast_notice, no_strikes_message)
}

m <- m %>%
  addControl(html = paste0(
    "<div id='info-panel-container' style='background: white; border-radius: 4px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); max-width: 400px; min-width: 300px;'>",
    "<button id='info-panel-toggle' style='width: 100%; padding: 8px 12px; background: #2c3e50; color: white; border: none; cursor: pointer; font-weight: bold; font-size: 0.9em; text-align: left; border-radius: 4px 4px 0 0; transition: background 0.2s;' onmouseover='this.style.background=\"#34495e\"' onmouseout='this.style.background=\"#2c3e50\"'>",
    "▶ Lightning Info",
    "</button>",
    "<div id='info-panel-content' style='display: none; padding: 12px; max-height: 60vh; overflow-y: auto;'>",
    header_content,
    "</div>",
    "</div>"
  ), position = "topleft") %>%
  addControl(html = "<div id='opacity-control' style='padding: 10px; background: white; border-bottom: 1px solid #ccc;'>
    <label for='fire-danger-opacity-slider' style='display: block; margin-bottom: 5px;'>Fire Danger Opacity:</label>
    <input type='range' id='fire-danger-opacity-slider' min='0' max='1' step='0.01' value='0.8'>
  </div>", position = "topright") %>%
  onRender("
    function(el, x) {
      var map = this;
      var slider = document.getElementById('fire-danger-opacity-slider');

      var evthandler = function(e){
        var newOpacity = +e.target.value;

        // Search for the Fire Danger layer group
        map.eachLayer(function(layer) {
          // Check if this is the Fire Danger layer group (contains the actual raster layer)
          if (layer.groupname === 'Fire Danger') {
            // This is a LayerGroup, iterate through its layers
            if (layer._layers) {
              Object.keys(layer._layers).forEach(function(key) {
                var sublayer = layer._layers[key];

                // Set opacity on the sublayer
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

      // Disable map dragging when interacting with the slider (mouse events)
      var sliderElement = document.getElementById('fire-danger-opacity-slider');

      sliderElement.addEventListener('mousedown', function() {
        map.dragging.disable();
      });
      sliderElement.addEventListener('mouseup', function() {
        map.dragging.enable();
      });

      // Disable map dragging when interacting with the slider (touch events)
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

      // Attach event listener to the slider
      slider.oninput = evthandler;

      // Toggle information panel (starts collapsed)
      var toggleButton = document.getElementById('info-panel-toggle');
      var panelContent = document.getElementById('info-panel-content');
      var isCollapsed = true;

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

# Save the map with fullscreen styling
out_dir <- here("out", "forecasts", ecoregion_name_clean, forecast_date_str)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# Create the widget
map_widget <- saveWidget(m, file.path(out_dir, "lightning_map.html"), selfcontained = TRUE)

# Add custom CSS for fullscreen layout
html_file <- file.path(out_dir, "lightning_map.html")
html_content <- readLines(html_file)

# Find the closing </head> tag and insert CSS before it
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
  "  /* Consistent slider styling for all devices */",
  "  #fire-danger-opacity-slider {",
  "    width: 100% !important;",
  "    -webkit-appearance: none !important;",
  "    appearance: none !important;",
  "    background: linear-gradient(to right, #95a5a6 0%, #95a5a6 100%) !important;",
  "    background-size: 100% 8px !important;",
  "    background-position: center !important;",
  "    background-repeat: no-repeat !important;",
  "    cursor: pointer;",
  "    height: 20px;",
  "    border: none !important;",
  "    border-radius: 4px !important;",
  "  }",
  "  #fire-danger-opacity-slider::-webkit-slider-track {",
  "    width: 100% !important;",
  "    height: 8px !important;",
  "    background: #95a5a6 !important;",
  "    border-radius: 4px !important;",
  "    border: 1px solid #7f8c8d !important;",
  "  }",
  "  #fire-danger-opacity-slider::-webkit-slider-thumb {",
  "    width: 20px !important;",
  "    height: 20px !important;",
  "    background: #2c3e50 !important;",
  "    border-radius: 50% !important;",
  "    cursor: pointer;",
  "    -webkit-appearance: none !important;",
  "    appearance: none !important;",
  "    margin-top: -6px;",
  "  }",
  "  #fire-danger-opacity-slider::-moz-range-track {",
  "    width: 100% !important;",
  "    height: 8px !important;",
  "    background: #95a5a6 !important;",
  "    border-radius: 4px !important;",
  "    border: 1px solid #7f8c8d !important;",
  "  }",
  "  #fire-danger-opacity-slider::-moz-range-thumb {",
  "    width: 20px !important;",
  "    height: 20px !important;",
  "    background: #2c3e50 !important;",
  "    border-radius: 50% !important;",
  "    cursor: pointer;",
  "    border: none;",
  "  }",
  "  /* Mobile optimizations */",
  "  @media screen and (max-width: 768px) {",
  "    /* Move opacity slider to bottom-left corner */",
  "    #opacity-control {",
  "      position: fixed !important;",
  "      bottom: 10px !important;",
  "      left: 10px !important;",
  "      top: auto !important;",
  "      right: auto !important;",
  "      z-index: 1000;",
  "      max-width: 200px;",
  "    }",
  "    /* Keep layers control in top-right, just give it space below banner */",
  "    .leaflet-top.leaflet-right {",
  "      top: 60px !important;",
  "    }",
  "    .leaflet-control {",
  "      margin: 5px !important;",
  "    }",
  "    .leaflet-bottom.leaflet-right {",
  "      margin-bottom: 10px !important;",
  "    }",
  "    #info-panel-container {",
  "      max-width: 90vw !important;",
  "      min-width: 280px !important;",
  "    }",
  "    /* Improve touch target sizes on mobile */",
  "    #fire-danger-opacity-slider {",
  "      height: 30px !important;",
  "    }",
  "    #fire-danger-opacity-slider::-webkit-slider-thumb {",
  "      width: 24px !important;",
  "      height: 24px !important;",
  "      margin-top: -8px !important;",
  "    }",
  "    #fire-danger-opacity-slider::-moz-range-thumb {",
  "      width: 24px !important;",
  "      height: 24px !important;",
  "    }",
  "  }",
  "</style>"
)

html_content <- c(
  html_content[1:(head_close_idx - 1)],
  fullscreen_css,
  html_content[head_close_idx:length(html_content)]
)

# Find the opening <body> tag and insert banner right after it
body_open_idx <- which(grepl("<body", html_content))[1]
banner_html <- paste0("<div id='update-banner'>", update_notice_banner, "</div>")

html_content <- c(
  html_content[1:body_open_idx],
  banner_html,
  html_content[(body_open_idx + 1):length(html_content)]
)

writeLines(html_content, html_file)

message(glue("Lightning map saved to: {html_file}"))
message(glue("Lightning map generation complete for {ecoregion_name}"))
