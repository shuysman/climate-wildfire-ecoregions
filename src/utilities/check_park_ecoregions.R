library(terra)
library(tidyverse)

# Load ecoregions and parks
ecoregions <- vect("data/us_eco_l3/us_eco_l3.shp")
parks <- vect("data/nps_boundary/nps_boundary.shp")

# Focus on major western parks
major_parks <- c("YELL", "GRTE", "ROMO", "GLAC", "YOSE", "GRSM", "OLYM", "SEKI", "REDW", "LAVO", "CRLA")
parks_subset <- parks[parks$UNIT_CODE %in% major_parks, ]

# Project to consistent CRS
parks_subset <- project(parks_subset, crs(ecoregions))

# For each park, find which ecoregions it intersects
results <- list()
for (i in 1:nrow(parks_subset)) {
  park <- parks_subset[i, ]
  intersecting_eco <- ecoregions[park, ]

  if (nrow(intersecting_eco) > 0) {
    areas <- expanse(intersect(park, intersecting_eco)[[1]], unit = "km")
    total_area <- expanse(park, unit = "km")

    eco_names <- intersecting_eco$US_L3NAME
    eco_ids <- intersecting_eco$US_L3CODE

    results[[i]] <- data.frame(
      park_code = park$UNIT_CODE,
      park_name = park$UNIT_NAME,
      total_area_km2 = round(total_area, 1),
      num_ecoregions = nrow(intersecting_eco),
      ecoregion_names = paste(eco_names, collapse = " | "),
      ecoregion_ids = paste(eco_ids, collapse = ", "),
      area_pct = paste(round(areas / total_area * 100, 1), collapse = ", ")
    )
  }
}

results_df <- bind_rows(results) %>% arrange(desc(num_ecoregions))
print(results_df, width = 200)
