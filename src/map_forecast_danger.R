### Proof of concept script illustrating how to map wildfire ignition
### danger. Percentile of n-day rolling sum of VPD is estimated by
### comparing rolling sums of VPD to precalculated quantiles of VPD.
### This enables more rapid estimation of percentiles with low memory
### requirements to allow for estimation across large areas which
### would otherwise by memory-limited. Wildfire ignition danger is
### represented as a value from 0-1, which are the historical
### proportion of wildfires that burned at or below the corresponding
### percentile of dryness.

library(tidyverse)
library(terra)
library(tidyterra)
library(glue)
library(maptiles)
library(climateR)

bin_rast <- function(new_rast, quants_rast, probs) {
  # Count how many quantile layers the new value is greater than.
  # This results in a raster of integers from 0 to 9.
  bin_index_rast <- sum(new_rast > quants_rast)

  # Now, map this integer index back to a percentile value.
  # We need a mapping from [0, 1, 2, ..., 9] to [0, 0.1, 0.2, ..., 0.9]
  # A value of 0 means it was smaller than the 1st quantile (q_0.1)
  # A value of 9 means it was larger than the 9th quantile (q_0.9)
  percentile_map <- c(0, probs)
  from_vals <- 0:length(probs)
  rcl_matrix <- cbind(from_vals, percentile_map)

  # Use classify to create the final approximate percentile raster
  percentile_rast_binned <- classify(bin_index_rast, rcl = rcl_matrix)

  return(percentile_rast_binned)
}


terraOptions(
  verbose = FALSE,
  memfrac = 0.9
)

out_dir <- file.path("./out/forecasts")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## Optimal rolling windows determined by dryness analysis script

probs <- seq(.01, 1.0, by = .01)

nps_boundaries <- vect("data/nps_boundary/nps_boundary.shp") %>%
  filter(UNIT_CODE %in% c("YELL", "GRTE", "JODR"))

forest_quants_rast <- rast("./out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-quants.nc")
non_forest_quants_rast <- rast("./out/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-5-VPD-quants.nc")


### Today's Forecast File
vpd_forecast_0 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_0.nc")
time(vpd_forecast_0) <- as_date(depth(vpd_forecast_0), origin = "1900-01-01")

### Yesterday's Forecast File
vpd_forecast_1 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_1.nc")
time(vpd_forecast_1) <- as_date(depth(vpd_forecast_1), origin = "1900-01-01")

### Two Day old Forecast File
vpd_forecast_2 <- rast("data/vpd/cfsv2_metdata_forecast_vpd_daily_2.nc")
time(vpd_forecast_2) <- as_date(depth(vpd_forecast_2), origin = "1900-01-01")

nps_boundaries <- project(nps_boundaries, crs(vpd_forecast_0))

vpd_forecast_0 <- crop(vpd_forecast_0, nps_boundaries)
vpd_forecast_1 <- crop(vpd_forecast_1, nps_boundaries)
vpd_forecast_2 <- crop(vpd_forecast_2, nps_boundaries)

### Retrieve historical gridMET data through today - 2
today <- today()
start_date <- today - 40

### Check if most recent forecast is available or raise error
### Most recent forecast should be vpd_forecast_0 which starts from tomorrow
most_recent_forecast <- time(subset(vpd_forecast_0, 1))
if (most_recent_forecast != today + 1) {
  stop(glue("Most recent forecast date is {most_recent_forecast} but should be {most_recent_forecast + 1}. Exiting..."))
}

vpd_gridmet <- tryCatch(
  {
    getGridMET(
      AOI = nps_boundaries,
      varname = "vpd",
      startDate = start_date,
      endDate = today - 2,
      verbose = TRUE
    )$daily_mean_vapor_pressure_deficit %>%
      project(crs(vpd_forecast_0)) %>%
      crop(vpd_forecast_0)
  },
  error = function(e) {
    warning("Failed to retrieve gridMET data. Using older forecast data as a fallback. Forecast accuracy may be reduced.")
    # Fallback to using older forecast data
    c(
      subset(vpd_forecast_2, time(vpd_forecast_2) < today - 1),
      subset(vpd_forecast_1, time(vpd_forecast_1) < today)
    )
  }
)


today_vpd <- subset(vpd_forecast_1, time(vpd_forecast_1) == today)
yesterday_vpd <- subset(vpd_forecast_2, time(vpd_forecast_2) == today - 1)
vpd_series <- c(vpd_gridmet, yesterday_vpd, today_vpd, vpd_forecast_0)

dates <- time(vpd_series)




forest_data <- terra::roll(vpd_series, n = 15, fun = mean, type = "to", circular = FALSE, overwrite = TRUE)
non_forest_data <- terra::roll(vpd_series, n = 5, fun = mean, type = "to", circular = FALSE, overwrite = TRUE)

forest_fire_danger_rast <- rast()
forest_fire_danger_ecdf <- readRDS("./out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-ecdf.RDS")
for (n in 1:nlyr(forest_data)) {
  forest_percentile_rast <- bin_rast(subset(forest_data, n), forest_quants_rast, probs)
  forest_fire_danger_rast <- c(forest_fire_danger_rast, terra::app(forest_percentile_rast, fun = \(x) forest_fire_danger_ecdf(x)))
}

time(forest_fire_danger_rast) <- dates

non_forest_fire_danger_rast <- rast()
non_forest_fire_danger_ecdf <- readRDS("./out/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-5-VPD-ecdf.RDS")
for (n in 1:nlyr(non_forest_data)) {
  non_forest_percentile_rast <- bin_rast(subset(non_forest_data, n), non_forest_quants_rast, probs)
  non_forest_fire_danger_rast <- c(non_forest_fire_danger_rast, terra::app(non_forest_percentile_rast, fun = \(x) non_forest_fire_danger_ecdf(x)))
}

time(non_forest_fire_danger_rast) <- dates

cover_types <- rast("data/LF2023_EVT_240_CONUS/Tif/4326/LC23_EVT_240.tif") %>%
  crop(forest_fire_danger_rast)

activeCat(cover_types) <- "EVT_LF"

# 1. Extract the category levels into a data frame
# The [[1]] is used because levels() returns a list, one for each layer.
categories_df <- levels(cover_types)[[1]]

# 2. Add a new column with the desired classification using your rules
# We will create numeric codes: 1 for non_forest, 2 for forest.
# Everything else will become NA.
categories_df <- categories_df %>%
  mutate(veg_class_id = case_match(
    EVT_LF,
    c("Herb", "Shrub", "Sparse") ~ 1,
    "Tree" ~ 2,
    .default = NA_integer_
  ))

# 3. Create the reclassification matrix from the original ID to the new ID
# The matrix should have two columns: 'from' (original ID) and 'to' (new ID).
# The original raster values are in the 'ID' or 'value' column of the levels table.
rcl_matrix <- categories_df[, c("Value", "veg_class_id")]

# 4. Classify the raster using this matrix
classified_rast <- classify(cover_types, rcl = rcl_matrix, right = NA)

# 5. (Optional but recommended) Assign new category labels to the output raster
new_levels <- data.frame(
  ID = c(1, 2),
  cover = c("non_forest", "forest")
)
levels(classified_rast) <- new_levels

# View the result
## print(classified_rast)
## plot(classified_rast)

forest_mask <- classified_rast == 2
forest_mask <- subst(forest_mask, FALSE, NA)
non_forest_mask <- classified_rast == 1
non_forest_mask <- subst(non_forest_mask, FALSE, NA)

basemap <- get_tiles(classified_rast, provider = "Esri.NatGeoWorldMap", zoom = 9) %>%
  crop(classified_rast)

forest_fire_danger_rast <- forest_fire_danger_rast %>%
  # subset(time(.) >= today & time(.) <= today + 7) %>%
  resample(classified_rast)

non_forest_fire_danger_rast <- non_forest_fire_danger_rast %>%
  # subset(time(.) >= today & time(.) <= today + 7) %>%
  resample(classified_rast)

names(forest_fire_danger_rast) <- time(forest_fire_danger_rast)
names(non_forest_fire_danger_rast) <- time(non_forest_fire_danger_rast)

combined_fire_danger_rast <- cover(
  mask(forest_fire_danger_rast, forest_mask),
  mask(non_forest_fire_danger_rast, non_forest_mask)
)

ggplot() +
  geom_spatraster_rgb(data = basemap) +
  geom_spatraster(data = subset(combined_fire_danger_rast, time(combined_fire_danger_rast) >= today)) +
  scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  facet_wrap(~lyr, ncol = 5) +
  theme(axis.text.x = element_text(angle = 45, vjust = 1, hjust = 1)) +
  labs(title = glue("Wildfire danger forecast for YELL/GRTE/JODR from {today}"), fill = "Proportion of Fires") +
  scale_x_continuous(expand = c(0, 0)) +
  scale_y_continuous(expand = c(0, 0))
ggsave(file.path(out_dir, glue("YELL-GRTE-JODR_fire_danger_forecast_{today}.png")), width = 12, height = 20)

forecast_rast <- subset(combined_fire_danger_rast, time(combined_fire_danger_rast) %in% dates[15:length(dates)]) ### Filter out early dates because the earliest date without NAs for forest is start_date + 14 due to rolling window calculation
saveRDS(forecast_rast, file.path(out_dir, glue("fire_danger_forecast_{today}.rds")))
