## Write quantiles layer for forest and non-forest cover types in YELL, JODR, and GRTE for n-day rolling averages of VPD

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

## Optimal rolling windows determined by dryness analysis script

probs <- seq(.01, 1.0, by = .01)

middle_rockies <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  filter(US_L3NAME == "Middle Rockies")

vpd_data_dir <- file.path("/media/steve/THREDDS/gridmet/")
vpd_data_files <- list.files(vpd_data_dir, pattern = "vpd.*.nc", full.names = TRUE)
vpd_data <- rast(vpd_data_files) %>%
  crop(project(middle_rockies, crs(.))) %>%
  mask(project(middle_rockies, crs(.)))

time(vpd_data) <- as_date(depth(vpd_data), origin = "1900-01-01")

forest_quants_rast <- terra::roll(vpd_data, n = 15, fun = mean, type = "to", circular = FALSE, overwrite = TRUE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

writeCDF(forest_quants_rast, "./data/ecdf/17-middle_rockies-forest/17-middle_rockies-forest-15-VPD-quants.nc", overwrite = TRUE, split = TRUE)

non_forest_quants_rast <- terra::roll(vpd_data, n = 5, fun = mean, type = "to", circular = FALSE, overwrite = TRUE) %>%
  terra::round(digits = 1) %>%
  subst(0, NA) %>%
  terra::app(function(x) replace_duplicated(x)) %>%
  terra::quantile(probs = probs, na.rm = TRUE)

writeCDF(non_forest_quants_rast, "./data/ecdf/17-middle_rockies-non_forest/17-middle_rockies-non_forest-5-VPD-quants.nc", overwrite = TRUE, split = TRUE)
