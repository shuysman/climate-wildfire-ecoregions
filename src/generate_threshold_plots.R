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
for (park_code in park_codes) {
  park_poly <- parks_in_ecoregion[parks_in_ecoregion$UNIT_CODE == park_code, ]
  park_name <- park_poly$UNIT_NAME

  message(paste("Processing thresholds for:", park_name))

  # Create park-specific output directory
  park_out_dir <- here("out", "forecasts", park_code)
  dir.create(park_out_dir, showWarnings = FALSE, recursive = TRUE)

  # Crop fire danger raster to the park boundary
  park_fire_danger_rast <- crop(fire_danger_rast, park_poly, mask = TRUE)

  # Loop through thresholds and generate plots for the park
  for (threshold in thresholds) {
    # Threshold the raster
    thresholded_rast <- park_fire_danger_rast >= threshold

    # Calculate the percentage of cells above the threshold for each layer
    percent_above <- global(thresholded_rast, fun = "mean", na.rm = TRUE)

    percent_above$date <- time(park_fire_danger_rast)

    ## Split date for rectangle annotations on thresholdplot
    split_date <- today - 1.5

    p <- ggplot(percent_above, aes(x = date, y = mean)) +
      annotate("rect",
        xmin = min(percent_above$date) - .5, xmax = split_date,
        ymin = -Inf, ymax = Inf, fill = "blue", alpha = 0.2
      ) +
      annotate("rect",
        xmin = split_date, xmax = max(percent_above$date) + .5,
        ymin = -Inf, ymax = Inf, fill = "green", alpha = 0.2
      ) +
      geom_col() +
      geom_vline(xintercept = today, color = "red", linetype = "dashed", size = 1.25) +
      annotate("text", x = today, y = Inf, label = "Today", vjust = -0.5, color = "red", fontface = "bold") +
      scale_x_date(date_breaks = "1 day", expand = c(0, 0)) +
      theme(axis.text.x = element_text(angle = 90, vjust = 0.5)) +
      scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
      labs(
        y = "% of Area at or Above Threshold", x = "Date",
        title = glue("Percentage of {park_name} at or Above {threshold} Fire Danger"),
        caption = "Blue background: Historical data (up to 2 days ago)\nGreen background: Forecast data (from yesterday onwards)"
      )

    # Save the plot to the park-specific directory
    ggsave(file.path(park_out_dir, glue("threshold_plot_{threshold}.png")), plot = p, height = 4, width = 8)
  }
}
