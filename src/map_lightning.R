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

# Get command line arguments, using a unique variable name to avoid conflicts
cmd_args <- commandArgs(trailingOnly = TRUE)
if (length(cmd_args) != 3) {
  stop("Usage: Rscript map_lightning.R <cog_file> <forecast_status> <forecast_date>", call. = FALSE)
}

cog_file <- cmd_args[1]
forecast_status <- cmd_args[2]
forecast_date_str <- cmd_args[3]
forecast_date <- as.Date(forecast_date_str)

# Load the single-layer COG file
if (!file.exists(cog_file)) {
  stop("COG file not found at: ", cog_file)
}

# The input is now a single-layer raster for today, so no subsetting is needed.
fire_danger_today <- rast(cog_file)
fire_danger_today <- aggregate(fire_danger_today, fact = 2)

# Load NPS boundaries
nps_boundaries <- vect(here("data", "nps_boundary", "nps_boundary.shp")) %>%
  project(crs(fire_danger_today)) # Ensure CRS matches the raster

# Trim raster to the extent of non-NA values and filter parks
trimmed_raster <- trim(fire_danger_today)
intersecting_parks <- nps_boundaries[ext(trimmed_raster), ]

# Define styling for park boundaries
park_line_color <- "#000000" # Black
park_fill_color <- "transparent" # No fill
park_line_weight <- 1
park_fill_opacity <- 0.5

# Fetch lightning data
# Securely fetch the API key from AWS Secrets Manager
api_key <- tryCatch(
  {
    message("Fetching API key from AWS Secrets Manager...")
    secrets_manager <- paws::secretsmanager()
    secret_payload <- secrets_manager$get_secret_value(SecretId = "wildfire-forecast/weatherbit-api-key")
    secret_list <- jsonlite::fromJSON(secret_payload$SecretString)
    secret_list$WEATHERBIT_API_KEY
  },
  error = function(e) {
    stop("Failed to retrieve API key from AWS Secrets Manager. Error: ", e$message)
  }
)

if (is.null(api_key) || api_key == "") {
  stop("API key retrieved from Secrets Manager is null or empty.")
}

api_url <- glue("https://api.weatherbit.io/v2.0/history/lightning?lat=43.5459517032319&lon=-111.162554452619&end_lat=45.1292422224309&end_lon=-109.829085745439&date={forecast_date_str}&key={api_key}")

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
  addRasterImage(fire_danger_today, colors = pal, opacity = 0.8, project = TRUE, maxBytes = 64 * 1024 * 1024) %>%
  addPolygons(
    data = intersecting_parks,
    color = park_line_color,
    weight = park_line_weight,
    fillColor = park_fill_color,
    fillOpacity = park_fill_opacity,
    popup = ~UNIT_NAME
  ) %>% # Add popup for park name
  addLegend(
    pal = pal, values = c(0, 1),
    title = "Fire Danger"
  ) %>%
  fitBounds(ext(fire_danger_today)$xmin[[1]], ext(fire_danger_today)$ymin[[1]], ext(fire_danger_today)$xmax[[1]], ext(fire_danger_today)$ymax[[1]])

# Create HTML for the header
header_title <- "<h1>Lightning Strike Information</h1>"
update_time <- paste("<p>Last updated:", Sys.time(), "</p>")

# Initialize an empty notice
forecast_notice <- ""

# Create a notice ONLY if the forecast is old
if (forecast_status != "Current") {
  notice_text <- "Notice: The latest forecast is not yet available. The fire danger shown is based on older data."
  notice_color <- "#D9534F" # Reddish color for a warning
  forecast_notice <- paste0("<p style=\"color: ", notice_color, ";\"><i>", notice_text, "</i></p>")
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

    # Create the HTML table
    lightning_table_html <- paste(
      "<table class=\"table table-striped\">",
      "<thead><tr><th>Latitude</th><th>Longitude</th><th>Timestamp</th><th>Fire Danger</th></tr></thead>",
      "<tbody>",
      paste(apply(lightning_table_data, 1, function(row) {
        paste("<tr><td>", row["Latitude"], "</td><td>", row["Longitude"], "</td><td>", row["Timestamp"], "</td><td>", row["Fire_Danger"], "</td></tr>")
      }), collapse = ""),
      "</tbody></table>"
    )

    # Wrap the table in a scrollable div
    lightning_table <- paste0(
      "<div style=\"max-height: 400px; overflow-y: auto; border: 1px solid #ddd;\">",
      lightning_table_html,
      "</div>"
    )

    header_content <- paste(header_title, update_time, forecast_notice, lightning_table)
  } else {
    no_strikes_message <- paste0("<p>No lightning strikes recorded within the forecast area for ", forecast_date_str, ".</p>")
    header_content <- paste(header_title, update_time, forecast_notice, no_strikes_message)
  }
} else {
  no_strikes_message <- paste0("<p>No lightning strikes recorded for ", forecast_date_str, ".</p>")
  header_content <- paste(header_title, update_time, forecast_notice, no_strikes_message)
}

# Prepend header to the map
m <- m %>% prependContent(HTML(header_content))

# Save the map
out_dir <- here("out", "forecasts")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
saveWidget(m, file.path(out_dir, glue("lightning_map_{Sys.Date()}.html")), selfcontained = TRUE)
