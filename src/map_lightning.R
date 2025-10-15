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

# Get command line arguments
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) {
  stop("Usage: Rscript map_lightning.R <forecast_file_path> <forecast_status> <forecast_date>", call. = FALSE)
}

forecast_file <- args[1]
forecast_status <- args[2]
forecast_date_str <- args[3]
forecast_date <- as.Date(forecast_date_str)

# Load fire danger raster
if (!file.exists(forecast_file)) {
  stop("Forecast file not found at: ", forecast_file)
}

fire_danger_rast <- rast(forecast_file)

# Get the fire danger for the specified date
fire_danger_today <- fire_danger_rast %>% subset(time(.) == forecast_date)
fire_danger_today <- aggregate(fire_danger_today, fact = 2)

# Fetch lightning data
api_key_file <- here(".weatherbit_api_key")
if (!file.exists(api_key_file)) {
  stop("API key file not found at: ", api_key_file)
}
api_key <- trimws(readLines(api_key_file, n = 1, warn = FALSE))
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
  addRasterImage(fire_danger_today, colors = pal, opacity = 0.8, project = TRUE) %>%
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
  marker_pal <- colorNumeric(viridisLite::viridis(256, option = "B"), domain = c(0, 1), na.color = "#808080")
  marker_colors <- marker_pal(fire_danger_values[, 2])

  m <- m %>%
    addCircleMarkers(
      data = lightning_data$lightning, lng = ~lon, lat = ~lat, popup = ~ paste("Time:", timestamp_utc),
      color = marker_colors, radius = 5, stroke = FALSE, fillOpacity = 0.8
    )

  # Create a data frame for the table
  lightning_table_data <- data.frame(
    Latitude = lightning_data$lightning$lat,
    Longitude = lightning_data$lightning$lon,
    Timestamp = lightning_data$lightning$timestamp_utc,
    Fire_Danger = round(fire_danger_values[, 2], 2)
  )

  # Create the HTML table
  lightning_table <- paste(
    "<table class=\"table table-striped\">",
    "<thead><tr><th>Latitude</th><th>Longitude</th><th>Timestamp</th><th>Fire Danger</th></tr></thead>",
    "<tbody>",
    paste(apply(lightning_table_data, 1, function(row) {
      paste("<tr><td>", row["Latitude"], "</td><td>", row["Longitude"], "</td><td>", row["Timestamp"], "</td><td>", row["Fire_Danger"], "</td></tr>")
    }), collapse = ""),
    "</tbody></table>"
  )
  header_content <- paste(header_title, update_time, forecast_notice, lightning_table)
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
