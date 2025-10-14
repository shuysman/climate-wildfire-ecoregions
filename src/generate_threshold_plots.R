library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(here)

# Hardcoded thresholds
thresholds <- c(0.25, 0.5, 0.75)

# Load fire danger raster
today <- today()
forecast_file <- here("out", "forecasts", glue("fire_danger_forecast_{today}.rds"))

if (!file.exists(forecast_file)) {
  stop("Forecast file not found at: ", forecast_file)
}

fire_danger_rast <- readRDS(forecast_file)

# Loop through thresholds and generate plots
for (threshold in thresholds) {
  # Threshold the raster
  thresholded_rast <- fire_danger_rast >= threshold

  # Calculate the percentage of cells above the threshold for each layer
  percent_above <- global(thresholded_rast, fun = "mean", na.rm = TRUE)

  percent_above$date <- time(fire_danger_rast)

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
      title = glue("Percentage of Parks at or Above {threshold} Fire Danger"),
      caption = "Blue background: Historical data (up to 2 days ago)\nGreen background: Forecast data (from yesterday onwards)"
    )

  # Save the plot
  out_dir <- here("out", "forecasts")
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  ggsave(file.path(out_dir, glue("threshold_plot_{threshold}.png")), plot = p, height = 4, width = 8)
}
