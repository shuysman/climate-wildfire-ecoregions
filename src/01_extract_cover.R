### Extract cover types and ecoregion for all MTBS polygons in database.
### Cover type is determined as the majority (mode) pixel count of
### landfire 2023 EVT cover in each polygon.

library(tidyverse)
library(terra)
library(tidyterra)


## Helper functions
## https://stackoverflow.com/questions/2547402/how-to-find-the-statistical-mode
Mode <- function(x) {
  ux <- unique(x)
  ux[which.max(tabulate(match(x, ux)))]
}

landfire_evt_2023 <- rast("data/LF2023_EVT_240_CONUS/Tif/LC23_EVT_240.tif")
activeCat(landfire_evt_2023) <- "EVT_LF"

metdata_elev <- rast("data/metdata_elevationdata.nc") ## For gridmet/NPSWB boundaries
# pyromes <- vect("data/pyromes/Data/Pyromes_CONUS_20200206.shp") ## We switched to ecoregions because of insufficient MTBS sample size in many critical pyromes
ecoregions <- vect("data/us_eco_l3/us_eco_l3.shp")


## MTBS burned perimeter polygons
mtbs <- vect("data/mtbs/mtbs_perims_DD.shp") %>%
  # filter(!(Event_ID %in% bad_sites)) %>% ### Remove blacklisted sites
  filter(Incid_Type == "Wildfire") %>%
  crop(metdata_elev) %>%
  project(landfire_evt_2023)

evt_levels <- levels(landfire_evt_2023$EVT_LF) %>% as.data.frame()

mtbs_polys_with_cover <- extract(landfire_evt_2023, mtbs, fun = Mode, bind = TRUE) %>%
  mutate(EVT_LF = evt_levels$EVT_LF[match(EVT_LF, evt_levels$Value)]) %>%
  mutate(maj_veg_cl = case_match(
    EVT_LF,
    c("Herb", "Shrub", "Sparse") ~ "non_forest",
    "Tree" ~ "forest",
    .default = "other"
  )) %>%
  filter(maj_veg_cl %in% c("forest", "non_forest"))


## Make spatvector of MTBS centroids
mtbs_centroids <- mtbs %>%
  as_tibble() %>%
  mutate(
    BurnBndLon = as.numeric(BurnBndLon),
    BurnBndLat = as.numeric(BurnBndLat)
  ) %>%
  vect(geom = c("BurnBndLon", "BurnBndLat"), crs = crs("EPSG:4326")) %>%
  project(ecoregions)


mtbs_centroids_ecoregions <- intersect(mtbs_centroids, ecoregions)

## ecoregions_df <- as.data.frame(ecoregions)

## mtbs_centroids_ecoregions <- mtbs_centroids_ecoregions %>% left_join(ecoregions_df, by = join_by(PYROME))

mtbs_centroids_ecoregions_df <- as.data.frame(mtbs_centroids_ecoregions) %>%
  select(Event_ID, US_L3CODE, US_L3NAME)

mtbs_polys_with_cover_ecoregions <- mtbs_polys_with_cover %>%
  left_join(mtbs_centroids_ecoregions_df, by = join_by(Event_ID))

mtbs_polys_with_cover_ecoregions %>%
  writeVector("data/mtbs_polys_plus_cover_ecoregion.gpkg", overwrite = TRUE)

mtbs_polys_with_cover_ecoregions %>%
  as.data.frame() %>%
  group_by(US_L3NAME, US_L3CODE, maj_veg_cl) %>%
  summarize(n = n()) %>%
  write_csv("data/ecoregion_cover_counts.csv")
