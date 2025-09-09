### Proof of concept script illustrating how to map wildfire ignition
### danger. Percentile of n-day rolling sum of CWD is estimated by
### comparing rolling sums of CWD to precalculated quantiles of CWD.
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

replace_duplicated <- function(x) {
  x[duplicated(x)] <- NA
  return(x)
}

terraOptions(
  verbose = TRUE,
  memfrac = 0.9
)

out_dir <- file.path("out")

## Optimal rolling windows determined by dryness analysis script

probs <- seq(.01, 1.0, by = .01)

nps_boundaries <- vect("data/nps_boundary/nps_boundary.shp") %>%
  filter(UNIT_CODE %in% c("YELL", "GRTE", "JODR"))

cwd_data_dir <- file.path("/media/steve/THREDDS/daily_or_monthly/v2_historical/")
cwd_data_files <- list.files(cwd_data_dir, pattern = "*Deficit.nc4", full.names = TRUE)
cwd_data <- rast(cwd_data_files) %>%
  crop(project(nps_boundaries, crs(.))) %>%
  mask(project(nps_boundaries, crs(.))) %>%
  app(fun = \(x) x / 10)

forest_quants_rast <- terra::roll(cwd_data, n = 4, fun = sum, type = "to", circular = FALSE, overwrite = TRUE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

non_forest_quants_rast <- terra::roll(cwd_data, n = 18, fun = sum, type = "to", circular = FALSE, overwrite = TRUE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

forest_test <- terra::roll(cwd_data, n = 4, fun = sum, type = "to", circular = FALSE, overwrite = TRUE)
forest_test <- subset(forest_test, 2790:2795)

non_forest_test <- terra::roll(cwd_data, n = 18, fun = sum, type = "to", circular = FALSE, overwrite = TRUE)
non_forest_test <- subset(non_forest_test, 2790:2795)

example_time <- time(subset(rast(cwd_data_files), 2790:2795))
time(forest_test) <- example_time
time(non_forest_test) <- example_time


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



forest_fire_danger_rast <- rast()
for (n in 1:nlyr(forest_test)) {
  forest_percentile_rast <- bin_rast(subset(forest_test, n), forest_quants_rast, probs)
  forest_fire_danger_ecdf <- readRDS("/home/steve/sync/pyrome-fire/out/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-4-CWD-ecdf.RDS")
  forest_fire_danger_rast <- c(forest_fire_danger_rast, terra::app(forest_percentile_rast, fun = \(x) forest_fire_danger_ecdf(x)))
}

non_forest_fire_danger_rast <- rast()
for (n in 1:nlyr(non_forest_test)) {
  non_forest_percentile_rast <- bin_rast(subset(non_forest_test, n), non_forest_quants_rast, probs)
  non_forest_fire_danger_ecdf <- readRDS("/home/steve/sync/pyrome-fire/out/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-18-CWD-ecdf.RDS")
  non_forest_fire_danger_rast <- c(non_forest_fire_danger_rast, terra::app(non_forest_percentile_rast, fun = \(x) non_forest_fire_danger_ecdf(x)))
}

cover_types <- rast("data/LF2023_EVT_240_CONUS/Tif/LC23_EVT_240.tif") %>%
  project(forest_fire_danger_rast) %>%
  resample(forest_fire_danger_rast, method = "mode")
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
print(classified_rast)
plot(classified_rast)

forest_mask <- classified_rast == 2
forest_mask <- subst(forest_mask, FALSE, NA)
non_forest_mask <- classified_rast == 1
non_forest_mask <- subst(non_forest_mask, FALSE, NA)

fire_danger_rast %>%
  mask(non_forest_mask) %>%
  plet()

basemap <- get_tiles(classified_rast, provider = "Esri.NatGeoWorldMap", zoom = 9) %>%
  crop(classified_rast)

names(forest_fire_danger_rast) <- example_time
names(non_forest_fire_danger_rast) <- example_time

ggplot() +
  geom_spatraster_rgb(data = basemap) +
  geom_spatraster(data = mask(forest_fire_danger_rast, forest_mask)) +
  # scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  # ggnewscale::new_scale_fill() +
  geom_spatraster(data = mask(non_forest_fire_danger_rast, non_forest_mask)) +
  scale_fill_viridis_c(option = "B", na.value = "transparent", limits = c(0, 1)) +
  facet_wrap(~lyr)
ggsave("fire_danger_example.png", height = 8, width = 10)
