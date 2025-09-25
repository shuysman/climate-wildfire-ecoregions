library(tidyverse)
library(terra)
library(tidyterra)
library(RColorBrewer)
# library(ggpattern)

auc_data <- read_csv("out/auc_data.csv")

## Number of ecoregions should be 83
auc_data %>%
  group_by(ecoregion_id, cover) %>%
  summarize(n = n())

best_predictors <- read_csv("out/best_predictors.csv")

## Count of variable by ecoregion
best_predictors %>%
  ggplot() +
  geom_histogram(stat = "count", aes(var))

## Rolling window by predictor variable
best_predictors %>%
  ggplot() +
  geom_density(aes(window, color = var)) +
  theme_bw()


ecoregions <- vect("data/us_eco_l3/us_eco_l3.shp") %>%
  mutate(US_L3CODE = as.numeric(US_L3CODE)) %>%
  left_join(best_predictors, by = join_by(US_L3CODE == ecoregion_id))

forest <- filter(ecoregions, cover == "forest")
non_forest <- filter(ecoregions, cover == "non_forest")

nps_boundaries <- vect("./data/nps_boundary/nps_boundary.shp") %>%
  project(forest) %>%
  crop(forest)

ggplot() +
  geom_spatvector(data = ecoregions, fill = "white") +
  geom_spatvector(data = forest, aes(fill = var)) +
  # geom_sf_pattern(data = nps_boundaries, pattern = "crosshatch", pattern_fill = "white") +
  scale_fill_brewer(palette = "Set3") +
  ggtitle("Best fire predictors—forest")
ggsave("forest-predictors.png")

ggplot() +
  geom_spatvector(data = ecoregions, fill = "white") +
  geom_spatvector(data = non_forest, aes(fill = var)) +
  scale_fill_brewer(palette = "Set3") +
  ggtitle("Best fire predictors—non_forest")
ggsave("non_forest-predictors.png")

forest %>% ggplot() +
  geom_density(aes(window, color = var))

auc_data %>%
  filter(cover == "forest") %>%
  ggplot() +
  geom_boxplot(aes(AUC, y = name))

auc_data %>%
  filter(cover == "forest") %>%
  ggplot() +
  geom_boxplot(aes(AUC10, y = name))

auc_data %>%
  filter(cover == "non_forest") %>%
  ggplot() +
  geom_boxplot(aes(AUC, y = name))

non_forest %>% ggplot() +
  geom_density(aes(window, color = var))


auc_data %>%
  filter(ecoregion_id == 23) %>%
  pivot_longer(cols = c(AUC, AUC10, AUC20), names_to = "auc") %>%
  ggplot() +
  geom_line(aes(x = window, y = value, color = name)) +
  facet_wrap(vars(cover, auc), scales = "free_y")

auc_data %>%
  filter(ecoregion_id == 14) %>%
  slice_max(AUC)

auc_data %>%
  group_by(ecoregion_id, cover) %>%
  slice_max(AUC20) %>%
  view()



### Best predictors for Middle Rockies
mrockies_data <- auc_data %>%
  filter(ecoregion_name == "middle_rockies")

mrockies_data %>%
  pivot_longer(cols = c(AUC, AUC10, AUC20), names_to = "auc") %>%
  ggplot() +
  geom_line(aes(x = window, y = value, color = name)) +
  facet_wrap(vars(cover, auc), scales = "free_y")


### find best window for VPD for forest and non-forest to use with raw gridmet grids for POC. We can't use water balance yet because need to generate new grids each day. TODO?
mrockies_data %>%
  filter(name == "VPD") %>%
  filter(cover == "forest") %>%
  arrange(desc(AUC)) %>%
  print(n = 50)

## # A tibble: 31 × 8
##    name    AUC  AUC10 AUC20 window ecoregion_id ecoregion_name cover
##    <chr> <dbl>  <dbl> <dbl>  <dbl>        <dbl> <chr>          <chr>
##  1 VPD   0.933 0.0520 0.138      5           17 middle_rockies forest
##  2 VPD   0.932 0.0519 0.138      6           17 middle_rockies forest
##  3 VPD   0.933 0.0517 0.138      4           17 middle_rockies forest
##  4 VPD   0.932 0.0516 0.138     20           17 middle_rockies forest
##  5 VPD   0.931 0.0514 0.138     21           17 middle_rockies forest
##  6 VPD   0.930 0.0512 0.137     19           17 middle_rockies forest
##  7 VPD   0.931 0.0511 0.138     22           17 middle_rockies forest
##  8 VPD   0.930 0.0510 0.136     18           17 middle_rockies forest
##  9 VPD   0.932 0.0509 0.137      9           17 middle_rockies forest
## 10 VPD   0.931 0.0509 0.136     10           17 middle_rockies forest
## # ℹ 21 more rows
## # ℹ Use `print(n = ...)` to see more rows

mrockies_data %>%
  filter(name == "VPD") %>%
  filter(cover == "non_forest") %>%
  arrange(desc(AUC)) %>%
  print(n = 50)

## # A tibble: 31 × 8
##    name    AUC  AUC10 AUC20 window ecoregion_id ecoregion_name cover
##    <chr> <dbl>  <dbl> <dbl>  <dbl>        <dbl> <chr>          <chr>
##  1 VPD   0.901 0.0451 0.123     21           17 middle_rockies non_forest
##  2 VPD   0.904 0.0451 0.124     17           17 middle_rockies non_forest
##  3 VPD   0.901 0.0450 0.123     22           17 middle_rockies non_forest
##  4 VPD   0.903 0.0450 0.123     19           17 middle_rockies non_forest
##  5 VPD   0.901 0.0449 0.123     20           17 middle_rockies non_forest
##  6 VPD   0.900 0.0449 0.123     26           17 middle_rockies non_forest
##  7 VPD   0.901 0.0449 0.123     24           17 middle_rockies non_forest
##  8 VPD   0.900 0.0449 0.123     27           17 middle_rockies non_forest
##  9 VPD   0.904 0.0448 0.123     16           17 middle_rockies non_forest
## 10 VPD   0.900 0.0448 0.123     25           17 middle_rockies non_forest
## # ℹ 21 more rows
## # ℹ Use `print(n = ...)` to see more rows
