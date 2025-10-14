library(tidyverse)
library(terra)
library(explore)

cover_data <- vect("./data/mtbs_polys_plus_cover_ecoregion.gpkg")

explore_all(select(as_tibble(cover_data), US_L3NAME, BurnBndAc, maj_veg_cl, Ig_Date), target = maj_veg_cl)

cover_data %>%
  as_tibble() %>%
  group_by(US_L3CODE, US_L3NAME, maj_veg_cl) %>%
  summarize(
    n = n()
  ) %>%
  filter(n >= 20) %>%
  arrange(as.numeric(US_L3CODE)) %>%
  View()

cover_data %>%
  as_tibble() %>%
  group_by(US_L3CODE, US_L3NAME) %>%
  summarize(
    n = n()
  ) %>%
  filter(n >= 20)


cover_data %>%
  as_tibble() %>%
  ggplot() +
  geom_histogram(stat = "count", aes(x = US_L3NAME, fill = maj_veg_cl), alpha = 0.75)
