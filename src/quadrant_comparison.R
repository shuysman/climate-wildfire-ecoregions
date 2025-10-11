##### Compare with Quadrant RAWS Station
### https://www.climateanalyzer.net/raws/quadrant/quadrant/get_years?display_option=segments
### To be ran after running map_forecast_danger.R
### This station is used to assess wildfire danger across the whole
### park. The goal here is to compare spatially-explicit wildfire
### danger with wildfire danger assessed at one point only.

quadrant_raws <- terra::vect(matrix(c(-110.99, 44.927619), ncol = 2), type = "points", crs = "+proj=longlat +datum=WGS84")

ggplot() +
  geom_spatvector(data = nps_boundaries) +
  geom_spatvector(data = quadrant_raws, shape = 4, size = 5) +
  geom_spatvector_text(data = quadrant_raws, label = "Quadrant", hjust = -.3) +
  xlab("") +
  ylab("")
ggsave("quadrant_map.png")

quadrant_forest_danger <- terra::extract(forest_fire_danger_rast, quadrant_raws) %>%
  pivot_longer(cols = -ID, names_to = "date", values_to = "Fire_danger") %>%
  mutate(cover = "forest")
quadrant_non_forest_danger <- terra::extract(non_forest_fire_danger_rast, quadrant_raws) %>%
  pivot_longer(cols = -ID, names_to = "date", values_to = "Fire_danger") %>%
  mutate(cover = "non_forest")

set.seed(255)
sample_size <- 1024

random_pts_forest_danger <- spatSample(forest_fire_danger_rast, size = 1024, na.rm = TRUE, as.df = TRUE) %>%
  tibble::rownames_to_column("ID") %>%
  pivot_longer(cols = -ID, names_to = "date", values_to = "Fire_danger") %>%
  mutate(cover = "forest")
random_pts_non_forest_danger <- spatSample(non_forest_fire_danger_rast, size = 1024, na.rm = TRUE, as.df = TRUE) %>%
  tibble::rownames_to_column("ID") %>%
  pivot_longer(cols = -ID, names_to = "date", values_to = "Fire_danger") %>%
  mutate(cover = "non_forest")

quadrant_fire_danger <- bind_rows(quadrant_forest_danger, quadrant_non_forest_danger)
random_pts_fire_danger <- bind_rows(random_pts_forest_danger, random_pts_non_forest_danger)


ggplot() +
  geom_ribbon(data = filter(random_pts_fire_danger, ID == 1), aes(x = date, ymin = 0, ymax = 0.1, group = ID), fill = "green") +
  geom_ribbon(data = filter(random_pts_fire_danger, ID == 1), aes(x = date, ymin = 0.1, ymax = 0.4, group = ID), fill = "yellow") +
  geom_ribbon(data = filter(random_pts_fire_danger, ID == 1), aes(x = date, ymin = 0.4, ymax = 0.75, group = ID), fill = "orange") +
  geom_ribbon(data = filter(random_pts_fire_danger, ID == 1), aes(x = date, ymin = 0.75, ymax = 1.0, group = ID), fill = "red") +
  geom_line(data = random_pts_fire_danger, aes(x = date, y = Fire_danger, group = ID), alpha = 0.5) +
  geom_line(data = quadrant_fire_danger, aes(x = date, y = Fire_danger, group = ID), color = "purple", lwd = 3) +
  # geom_label(data = quadrant_fire_danger[5, ], aes(x = date, y = Fire_danger, label = "Quadrant"), alpha = 0.5) +
  ylim(0, 1) +
  facet_wrap("~cover") +
  ggtitle("Quadrant (purple) vs. 1024 Random Points (black)") +
  theme(axis.text.x = element_text(angle = 90, vjust = 0.5, hjust = 1))
ggsave("quadrant_comparison.png", height = 4, width = 5)
